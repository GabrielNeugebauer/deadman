package app.deadman.seeker

import android.os.Bundle
import androidx.lifecycle.lifecycleScope
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    private lateinit var resultSender: ActivityResultSender

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must be registered before the activity reaches STARTED, and before
        // super.onCreate attaches the engine and calls configureFlutterEngine.
        resultSender = ActivityResultSender(this)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MwaChannel(
            sender = resultSender,
            scope = lifecycleScope,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
    }
}
