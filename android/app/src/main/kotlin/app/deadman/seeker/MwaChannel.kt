package app.deadman.seeker

import android.net.Uri
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.Blockchain
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.Solana
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import com.solana.mobilewalletadapter.clientlib.protocol.JsonRpc20Client.JsonRpc20RemoteException
import com.solana.mobilewalletadapter.common.ProtocolContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * `deadman/mwa` method channel backed by the Solana Mobile clientlib-ktx.
 *
 * Every method accepts optional `identityUri`, `iconUri`, `identityName` and
 * `cluster` args; when omitted, the values from the last call are reused.
 * Calls are serialized because ActivityResultSender allows one pending intent.
 */
class MwaChannel(
    private val sender: ActivityResultSender,
    private val scope: CoroutineScope,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val mutex = Mutex()
    private var identity: ConnectionIdentity? = null
    private var blockchain: Blockchain = Solana.Devnet

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "authorize", "signTransactions", "deauthorize" -> scope.launch {
                mutex.withLock { handle(call, result) }
            }
            else -> result.notImplemented()
        }
    }

    private suspend fun handle(call: MethodCall, result: MethodChannel.Result) {
        updateConfig(call)
        val connectionIdentity = identity
        if (connectionIdentity == null) {
            result.error("NO_IDENTITY", "identityUri, iconUri and identityName are required", null)
            return
        }
        val adapter = MobileWalletAdapter(connectionIdentity).also { it.blockchain = blockchain }

        try {
            when (call.method) {
                "authorize" -> authorize(adapter, result)
                "signTransactions" -> signTransactions(adapter, call, result)
                "deauthorize" -> deauthorize(adapter, call, result)
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException && !isInterrupted(e)) throw e
            fail(result, e.message ?: e.javaClass.simpleName, e)
        }
    }

    private suspend fun authorize(adapter: MobileWalletAdapter, result: MethodChannel.Result) {
        when (val r = adapter.transact(sender) { it }) {
            is TransactionResult.Success -> {
                val auth = r.authResult
                val account = auth.accounts.firstOrNull()
                val publicKey = account?.publicKey ?: auth.publicKey
                result.success(
                    mapOf(
                        "publicKey" to Base58.encode(publicKey),
                        "authToken" to auth.authToken,
                        "walletLabel" to (account?.accountLabel ?: auth.accountLabel),
                    ),
                )
            }
            else -> fail(result, r)
        }
    }

    private suspend fun signTransactions(
        adapter: MobileWalletAdapter,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val transactions = call.argument<List<ByteArray>>("transactions")
        if (transactions.isNullOrEmpty()) {
            result.error("BAD_ARGS", "transactions must be a non-empty list", null)
            return
        }
        // With a token, transact() reauthorizes; without, it authorizes. Either
        // way the signing request runs in the same association session.
        adapter.authToken = call.argument<String>("authToken")
        val r = adapter.transact(sender) {
            signTransactions(transactions.toTypedArray()).signedPayloads
        }
        when (r) {
            is TransactionResult.Success -> result.success(r.payload.toList())
            else -> fail(result, r)
        }
    }

    private suspend fun deauthorize(
        adapter: MobileWalletAdapter,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val token = call.argument<String>("authToken")
        if (token.isNullOrEmpty()) {
            result.error("BAD_ARGS", "authToken is required", null)
            return
        }
        adapter.authToken = token
        when (val r = adapter.disconnect(sender)) {
            is TransactionResult.Success -> result.success(null)
            else -> fail(result, r)
        }
    }

    private fun updateConfig(call: MethodCall) {
        val identityUri = call.argument<String>("identityUri")
        val iconUri = call.argument<String>("iconUri")
        val identityName = call.argument<String>("identityName")
        if (identityUri != null && iconUri != null && identityName != null) {
            identity = ConnectionIdentity(Uri.parse(identityUri), Uri.parse(iconUri), identityName)
        }
        call.argument<String>("cluster")?.let { blockchain = blockchainFor(it) }
    }

    private fun blockchainFor(cluster: String): Blockchain = when (cluster) {
        "mainnet", "mainnet-beta", "solana:mainnet" -> Solana.Mainnet
        "testnet", "solana:testnet" -> Solana.Testnet
        else -> Solana.Devnet
    }

    private fun fail(result: MethodChannel.Result, r: TransactionResult<*>) {
        when (r) {
            is TransactionResult.NoWalletFound -> result.error("NO_WALLET", r.message, null)
            is TransactionResult.Failure -> fail(result, r.message, r.e)
            is TransactionResult.Success -> error("unreachable")
        }
    }

    private fun fail(result: MethodChannel.Result, message: String, e: Throwable) {
        val code = when {
            causes(e).any { it is android.content.ActivityNotFoundException } -> "NO_WALLET"
            isDeclined(e) -> "DECLINED"
            else -> "MWA_ERROR"
        }
        val detail = causes(e).lastOrNull()?.message
        result.error(code, if (detail != null && detail != message) "$message: $detail" else message, null)
    }

    private fun isDeclined(e: Throwable): Boolean = causes(e).any {
        (it is JsonRpc20RemoteException && it.code in DECLINE_CODES) || it is InterruptedException
    }

    private fun isInterrupted(e: Throwable): Boolean = causes(e).any { it is InterruptedException }

    private fun causes(e: Throwable): Sequence<Throwable> =
        generateSequence(e) { it.cause.takeIf { c -> c !== it } }.take(MAX_CAUSE_DEPTH)

    companion object {
        const val CHANNEL = "deadman/mwa"
        private const val MAX_CAUSE_DEPTH = 8
        private val DECLINE_CODES = setOf(
            ProtocolContract.ERROR_AUTHORIZATION_FAILED,
            ProtocolContract.ERROR_NOT_SIGNED,
        )
    }
}

internal object Base58 {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    fun encode(input: ByteArray): String {
        if (input.isEmpty()) return ""
        val leadingZeros = input.takeWhile { it == 0.toByte() }.size
        val digits = input.copyOf()
        val out = CharArray(input.size * 2)
        var outStart = out.size
        var start = leadingZeros
        while (start < digits.size) {
            var remainder = 0
            for (i in start until digits.size) {
                val acc = (remainder shl 8) or (digits[i].toInt() and 0xff)
                digits[i] = (acc / 58).toByte()
                remainder = acc % 58
            }
            out[--outStart] = ALPHABET[remainder]
            if (digits[start] == 0.toByte()) start++
        }
        repeat(leadingZeros) { out[--outStart] = '1' }
        return String(out, outStart, out.size - outStart)
    }
}
