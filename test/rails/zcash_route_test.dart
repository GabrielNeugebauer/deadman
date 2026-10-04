import 'dart:convert';

import 'package:deadman/rails/rails.dart';
import 'package:deadman/rails/zcash_route.dart';
import 'package:deadman/solana/codec.dart' show Limits;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

// Captured from https://1click.chaindefuser.com on 2026-10-02 (no funds sent).
const dryQuoteSol =
    r'''{"quote":{"amountIn":"1000000000","amountInFormatted":"1.0","amountInUsd":"118.980000000000","minAmountIn":"1000000000","amountOut":"8848584","amountOutFormatted":"0.08848584","amountOutUsd":"118.980000000000","minAmountOut":"8760098","timeEstimate":135,"refundFee":"86690","withdrawFee":"32000"},"quoteRequest":{"dry":true,"depositMode":"SIMPLE","swapType":"EXACT_INPUT","slippageTolerance":100,"originAsset":"nep141:sol.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"1000000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:57:30.000Z","confidentiality":"public","quoteWaitingTimeMs":0,"insured":false,"appFees":[{"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20}]},"signature":"ed25519:2ropA8ZmwCtjhAWYvXM6AgK2YuxqWz8sVn8uoUxTtavHCZ9t9mddVurBzYXGtTcSbrjMgGFCP67UpnSKoqx2omrT","timestamp":"2026-10-02T18:27:31.021Z","correlationId":"f26391dd-2073-4a43-8903-ec31619e0ce2"}''';
const quoteUsdc =
    r'''{"quote":{"amountIn":"5000000","amountInFormatted":"5.0","amountInUsd":"4.999690000000","minAmountIn":"5000000","amountOut":"340565","amountOutFormatted":"0.00340565","amountOutUsd":"4.575899453000","minAmountOut":"337159","timeEstimate":137,"refundFee":"318834","withdrawFee":"32000","deadline":"2026-10-05T18:59:39.000Z","timeWhenInactive":"2026-10-05T18:59:39.000Z","depositAddress":"E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg"},"quoteRequest":{"dry":false,"depositMode":"SIMPLE","swapType":"EXACT_INPUT","slippageTolerance":100,"originAsset":"nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"5000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:59:39.000Z","confidentiality":"public","referral":"deadman","quoteWaitingTimeMs":0,"insured":false,"appFees":[{"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20,"limitOrderId":null}]},"signature":"ed25519:4hT7wJUSrkvuhbHAUdFC7HmtrPoCPzgUzqvZT5iwgLZWnKDWEucjKi1pvamzHVLA4q3ZFEGav6WYpiGeHEjGZ4Pt","timestamp":"2026-10-02T18:29:39.675Z","correlationId":"48837116-8c91-41b3-89b3-3cb2469865eb"}''';
const statusPending =
    r'''{"status":"PENDING_DEPOSIT","updatedAt":"2026-10-02T18:29:40.097Z","correlationId":"92820c1f-f3cb-4c4c-91d9-d8428a3fc124","swapDetails":{"depositedAmount":null,"depositedAmountUsd":null,"depositedAmountFormatted":null,"intentHashes":[],"nearTxHashes":[],"amountIn":null,"amountInFormatted":null,"amountInUsd":null,"amountOut":null,"amountOutFormatted":null,"amountOutUsd":null,"slippage":null,"refundedAmount":"0","refundedAmountFormatted":"0","refundedAmountUsd":"0","refundReason":null,"refundFee":"318834","withdrawFee":"32000","originChainTxHashes":[],"destinationChainTxHashes":[]},"quoteResponse":{"timestamp":"2026-10-02T18:29:39.675Z","signature":"ed25519:4hT7wJUSrkvuhbHAUdFC7HmtrPoCPzgUzqvZT5iwgLZWnKDWEucjKi1pvamzHVLA4q3ZFEGav6WYpiGeHEjGZ4Pt","quoteRequest":{"dry":false,"swapType":"EXACT_INPUT","depositMode":"SIMPLE","slippageTolerance":100,"originAsset":"nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"5000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-02T18:59:39.000Z","appFees":[{"limitOrderId":null,"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20}],"virtualChainRecipient":null,"virtualChainRefundRecipient":null,"referral":"deadman","confidentiality":"public"},"quote":{"amountIn":"5000000","amountInFormatted":"5.0","amountInUsd":"4.999690000000","minAmountIn":"5000000","amountOut":"340565","amountOutFormatted":"0.00340565","amountOutUsd":"4.575899453000","minAmountOut":"337159","timeWhenInactive":"2026-10-05T18:59:39.000Z","depositAddress":"E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg","deadline":"2026-10-05T18:59:39.000Z","timeEstimate":137,"refundFee":"318834","withdrawFee":"32000"}}}''';

// Captured 2026-10-04 to the ZIP 316 test-vector address [u1Orchard].
const dryQuoteUsdt =
    r'''{"quote":{"amountIn":"5000000","amountInFormatted":"5.0","amountInUsd":"4.999465000000","minAmountIn":"5000000","amountOut":"343848","amountOutFormatted":"0.00343848","amountOutUsd":"4.566954751200","minAmountOut":"340409","timeEstimate":135,"refundFee":"327872","withdrawFee":"32000"},"quoteRequest":{"dry":true,"depositMode":"SIMPLE","swapType":"EXACT_INPUT","slippageTolerance":100,"originAsset":"nep141:sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near","depositType":"ORIGIN_CHAIN","destinationAsset":"nep141:zec.omft.near","amount":"5000000","refundTo":"13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK","refundType":"ORIGIN_CHAIN","recipient":"u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm0","recipientType":"DESTINATION_CHAIN","deadline":"2026-10-04T14:36:12.000Z","confidentiality":"public","referral":"deadman","quoteWaitingTimeMs":0,"insured":false,"appFees":[{"recipient":"5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd","fee":20}]},"signature":"ed25519:5HwcYyR12bLiWnHsH1FcNMrutyk4CJBLaSWx2cWB27Bdsx2FuzvDxcEtK6ScK6AW12tba2fLpwpG51oFwYtyfqdM","timestamp":"2026-10-04T14:06:13.145Z","correlationId":"d40bc50c-895e-4eca-9563-9c9848b75089"}''';

/// From the NEAR Intents explorer (Orchard + Sapling).
const u1 =
    'u1cv7rewjqmj395gla0zzfz669ntf6cr5hx9n983ct5t4dv0gphgyg5qjqe5re6ue5menlw94876wp0q90uf2cskh75rfvfejr564x8heq9zrs5p40n0fhqvehy8sjgxy0eu58l87w2mk48y3j07ggvgw5z5lncusl6y2a03rqau44ha2g';

/// Orchard-only, from zcash-test-vectors `unified_address.json` (seed
/// 0x00..1f, account 9, diversifier 0).
const u1Orchard =
    'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm0';

/// One per account of zcash-test-vectors `unified_address.json`, with the
/// receivers it carries (some also carry unknown typecodes).
const uaVectors = <(String, {bool o, bool s, bool t})>[
  (
    'u1l8xunezsvhq8fgzfl7404m450nwnd76zshscn6nfys7vyz2ywyh4cc5daaq0c7q2su5lqfh23sp7fkf3kt27ve5948mzpfdvckzaect2jtte308mkwlycj2u0eac077wu70vqcetkxf',
    o: false,
    s: true,
    t: true,
  ),
  (
    'u1pg2aaph7jp8rpf6yhsza25722sg5fcn3vaca6ze27hqjw7jvvhhuxkpcg0ge9xh6drsgdkda8qjq5chpehkcpxf87rnjryjqwymdheptpvnljqqrjqzjwkc2ma6hcq666kgwfytxwac8eyex6ndgr6ezte66706e3vaqrd25dzvzkc69kw0jgywtd0cmq52q5lkw6uh7hyvzjse8ksx',
    o: true,
    s: true,
    t: true,
  ),
  (
    'u1ay3aawlldjrmxqnjf5medr5ma6p3acnet464ht8lmwplq5cd3ugytcmlf96rrmtgwldc75x94qn4n8pgen36y8tywlq6yjk7lkf3fa8wzjrav8z2xpxqnrnmjxh8tmz6jhfh425t7f3vy6p4pd3zmqayq49efl2c4xydc0gszg660q9p',
    o: true,
    s: true,
    t: false,
  ),
  (
    'u1snf9yr883aj2hm8pksp9aymnqdwzy42rpzuffevj35hhxeckays5pcpeq7vy2mtgzlcuc4mnh9443qnuyje0yx6h59angywka4v2ap6kchh2j96ezf9w0c0auyz3wwts2lx5gmk2sk9',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1tqhg04ppjt6vlf2uvkygt07sqzgpclxdpn7j7ydkcr0e8ym68wn592z7uqudktrwn4u3q57flp8hw3d0wd9t0rm0e6m8eys27evfawh6zhha6eulzj86uz89swu7gtk0vcknd3dauhc96twhx20xxsp93dxahqlt7z5p04ldgy2y2lp0',
    o: true,
    s: true,
    t: false,
  ),
  (
    'u17cfcut587e3kszg8vud0z5a8lj9gyypyvtt5xn4hfc4p3kv4e0jfr2pzzxhywlkhsjldtmkvupwr7mkjvruz8gnxk7a64x777p4l3u7vpm6zsdsx88ef90x5q5sqx57fq8vtj5vk3hx',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1en8ysypun4gdkdnu8zqqg6k73ankr9ffwfzg08wtzg9z939w0wupewemfrc8a630e8gc4uqucym0l4v44fszy3et4veyypt3jsyp0whfpfsn2lw30kj8nepe6wvvasf00wklh85u9v8glqndupmamk9z2ja9sanf70pp4yxvkt3dmyzxa0kkhv2c9pxmkghrxqk0590azvya3nzrtevj449nu3laskrhf7c7nj9cyw7ty38mccg4znrr876guu6pzndx7ngwzhmlsn8d89saf5araaacrhr9958xr6z23mj4qtzzn98whdpu8u7n8fhf5d2vypljda62q73du44sf0e0kxmq3gvgkta0qqgq9w6r403gc5jz2any02etmwlttkv84hgh95czhdf2jugk3u36ke0kchcthg240',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1sem2gcey0emntrvxyjv8hyhq0w5fr4sxaj3cppgrfqgg6laydh8m78gy2cw2p54zzak3alnnsx4xjuhazpkrfcd90wl0c7ldj6y095hh5j6j2evry9vg5jqp4dyqpwqeryu7pes4sxyyyqwn6egs5daxk4473v9xpgzrwv5n0tvs93nlj4xpphq4vs2w8um9ph7zkte08t7fa509mnrt9apuhr22xq34mp2svjnq6rvfn0hg6lkehxtlj39vgjxjlkjfhx8rw2f02ckq8k5szcxsnhkgr2cqlmf2udl2gqdqr5t6',
    o: false,
    s: true,
    t: false,
  ),
  (
    'u1n9znrl4zyuvds24rcapzglzapqdlax4r8rgkvek0y0xlzfjfvn7zexelrafkchea24w030cr9jqsel7t8lvveaq7m7w4z0khmrlzc6748w9ldlccy02scd5xngtcv2yy4ctnyu9zn5m',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm0',
    o: true,
    s: false,
    t: false,
  ),
  (
    'u1xdrenc94696j8clxa2xnkdg8xd5t3y8s24urctyxu87vggv0u46qr4lkpnh7gqqdev9wwugt6xkv8c8du8ufhfl8nfjnzusf6cw20wpm85hlshmnmj2lkyhka9rua7qw7kr0xeajk7y2rlsuwl6z6l5l3wq3v6rrqt9e8zy7sc7pww45jznrj4xy6h9rp4kjy5xtl5upr30u4cyk58kv3t80k3p8w97k3e345h7avmjylxakx6sgyk5ss8th5kqay50ewav62eeep7tghzejaflsdstpwz55haex398jqpq27007me2',
    o: true,
    s: true,
    t: false,
  ),
  (
    'u1tqx832p4wsfe9pd67ggm3qsmfuvdhqvw2259y7uwug7y0lpeu87fmgpqh3zmamex3fzs0d4ct4hhsg2csj5z0q5f3f7n656ap8e4nlng9c4440rz9s7ekxanfw6g84f7vu82fumtmlz3vstl2a9ufa0970k4knsz2wpsjt2xycqeay76pt4fx3ak9y7mps2q6qe2n2h7wkakxr7xu6vd36zhhzgln7ttmrzc0f9ye3jmyu2pp8l8rect87lfxj2fgckcwz3svdx70a947fz04kgu7e907enzrk676zdkdmuyw2kyrclkmj62kmyy2rjetpus7knmxfuu7z0m63uwfhdynhuu3yrjqu5y089v8zwnh60mw5ngc0kszdjmc339fk9mjn396m5ekv7h7td7fa0u9097xph3y5vth9af4sw6ykxdms84wr544mxxqtmgj027d9e8rnlrazge0kwyydyhder3chwhmaqjk9skuxgxzternw4xx962qed',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1uehkuaq6rpfgt4ed5zpvhczg9apgpmyk5eq9qg23j8w7jxkhdnqzacte6gu8zgzfzgxy48ryzus3wnkhfxrxmlhs34xde3f34uxcnv3y6dsgj288vu56xs9f6ghvqsgkhuwtz4kkfxj8pa27v5p3ttlst340zvwx9nj6s0zw8p3wwk3zh37dwc7znqz52gj2fpaapzxzyagah0aeyxwa9fxxvyyj6w989v96ymsgf7s8s6ej9346p60fcjzzynvf9rmxevumdvt8l9mvhdfz4u5j4h7e0zjr2sde7fu7z9s02447qg6qzllm22egnx6ej6qczkkk2ygvpy08un9ggp853sddp6vskrlar6sygxec5f6c2t2eu9zmc728esy4sj9z853gxuplr6hw7lpcwzk20d85vuflnhlfv8nr3020r0v9z83ryudsyjv66rttxq2cscqlrdxakrmpjptzcf',
    o: true,
    s: false,
    t: false,
  ),
  (
    'u1dqavtnjvu42hlsjw6sc2mxajqlyt03zg8l4luykz9fnchunq74nqxhfp58h5n5xfpyqhheax8thta8lfkjgp8wqwsavc0g4mgu4du02c',
    o: true,
    s: false,
    t: false,
  ),
  (
    'u1ukslldhknrzmvpdmn03u03edgfy976w3muurfs9asvh3n9uh9h6sgle6m7yjgf3wafxtvke08u735v4nd3kjqnyulw7cvxh6ke357knyjudgqtes6kcw7y28e6kewr03pjah5mh26na',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u187vrwl4ampyxd5m6aj38n4ndkmj8v6gs97hkt23aps3sn5k89a0gk2smluexgdprcrtm56ezc5c7tjwlrnnl79tjtrxmqd42c5mpyz7g',
    o: false,
    s: true,
    t: false,
  ),
  (
    'u1smpx6drvevct3dyrer7esjlct99lf4nxdeltdetyxjdrmtqag7q7mkrd8rxlvj9e5vy0qy24fhvvvrj7agfdgxapefxe72xl8vuu9ds5yfq0p86r3y0jw4suurzjz5s6lzrxkfft4am',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1xjkw3lwwf9crx8cz050gdwfejufzhcusc37ged99w8fyj7tyx3e7hgmauyuv538dak2sepq6wjv4tyyjnhcef02dr682y5dsuzuftsx83lrvfc6dxd0kk260m4p3c9ka96vf3z9u6axvsj47mfd6kszy39e5gma28yg88yp92kxjt8ah0x329j4gxjdfyn0n2wp3urwrxxz6z0ynx82',
    o: true,
    s: true,
    t: true,
  ),
  (
    'u1udmzarqn6y9026whk083lm5vs8pv282egeln6xg0n2a3w4klkpn6208h68ntuus7gp54d937u4f724v2xgdx6qeu74j45vxfn822xty2yyx6u0ecakj8r9uu3r2jqafj64w7updkhtq',
    o: true,
    s: false,
    t: true,
  ),
  (
    'u1hrwrtyl3m8m2c6vkhu8wng43j5yvwweg37n2qstsqwc9dfw4vhs69m09064522758p44pfz42gu6hydjxua0wt0ge907sgrxkc9mft4gyfjevkhsyl4d8lnzgyd90arhx4t6v20zlfz',
    o: false,
    s: true,
    t: true,
  ),
];

const fixtureRefund = '13QkxhNMrTPxoCkRdYdJ65tFuwXPhL5gLS2Z5Nr6gjRK';
const usdc = 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v';
const usdt = 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB';
const rpc = 'https://rpc.test';
final quotedAt = DateTime.utc(2026, 10, 2, 18, 29, 39);

class Recorder {
  final requests = <http.Request>[];
  late final client = MockClient((req) async {
    requests.add(req);
    return handler(req);
  });
  Future<http.Response> Function(http.Request) handler = (_) async =>
      http.Response('{}', 500);

  Iterable<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path);

  Iterable<Map<String, dynamic>> rpcCalls(String method) => requests
      .where((r) => r.url.toString() == rpc)
      .map(body)
      .where((b) => b['method'] == method);
}

ZcashRoute route(
  Recorder r, {
  String cluster = 'mainnet-beta',
  String fee = '',
  List<Duration>? sleeps,
}) => ZcashRoute(
  client: r.client,
  cluster: cluster,
  rpcUrl: rpc,
  appFeeRecipient: fee,
  now: () => quotedAt,
  sleep: (d) async => sleeps?.add(d),
);

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, dynamic> body(http.Request r) =>
    jsonDecode(r.body) as Map<String, dynamic>;

Map<String, Object> systemAccount(int lamports) => {
  'lamports': lamports,
  'owner': SystemProgram.programId,
  'data': ['', 'base64'],
  'executable': false,
  'space': 0,
};

Map<String, Object> tokenAccount(int amount) => {
  'lamports': ZcashRoute.tokenAccountRentLamports,
  'owner': TokenProgram.programId,
  'data': {
    'program': 'spl-token',
    'parsed': {
      'type': 'account',
      'info': {
        'tokenAmount': {'amount': '$amount', 'decimals': 6},
      },
    },
    'space': 165,
  },
  'executable': false,
  'space': 165,
};

http.Response accounts(List<Object?> value) => json({
  'jsonrpc': '2.0',
  'id': 1,
  'result': {
    'context': {'slot': 1},
    'value': value,
  },
});

void main() {
  group('availability', () {
    test('mainnet only', () {
      final r = Recorder();
      expect(route(r).available, isTrue);
      expect(route(r, cluster: 'devnet').available, isFalse);
      expect(ZcashRoute(client: r.client).available, isFalse);
    });

    test('quote refuses off mainnet without calling out', () async {
      final r = Recorder();
      await expectLater(
        route(r, cluster: 'devnet').quote(
          claimKey: fixtureRefund,
          inputMint: null,
          amount: 1000000000,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });
  });

  group('unified address', () {
    test('decodes every zcash-test-vectors account', () {
      for (final (address, :o, :s, :t) in uaVectors) {
        expect(ZcashRoute.decodeUnifiedAddress(address), (
          orchard: o,
          sapling: s,
          transparent: t,
        ), reason: address);
        expect(ZcashRoute.isUnifiedAddress(address), isTrue, reason: address);
      }
    });

    test('decodes the explorer address used in live quotes', () {
      expect(ZcashRoute.decodeUnifiedAddress(u1), (
        orchard: true,
        sapling: true,
        transparent: false,
      ));
      expect(ZcashRoute.decodeUnifiedAddress(u1Orchard), (
        orchard: true,
        sapling: false,
        transparent: false,
      ));
    });

    test('rejects everything else', () {
      final rejected = {
        't1 transparent': 't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU',
        't3 transparent': 't3Vz22vK5z2LcKEdg16Yv4FFneEL1zg9ojd',
        'Sapling zs': 'zs1mrhc9y7jdh5r9ece8u5khgvj9kg0zgkxzdduyv0whkg7lkcrkx5xqem3e48avjq9wn2rukydkwn',
        'testnet utest': 'utest1nvzd4wf8mxnext5mze9rzqc8feq2wpv27fdl396yy5lwaq6q6f3q6tnzw2h2ujtsgn9mnvgf6w9u7d4aq2dpxtnxespwlhyzavz9jujt',
        'bech32 not bech32m': 'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynecvd0q7d',
        'one flipped char': 'u1ddnjsdcpm36r6aq79n3s68shjweksnmwtdltrh046s8m6xcws9ygyawalxx8n6hg6vegk0wh8zjnafxgh6msppjsljvyt0ynece3lvm2',
        'under 48 bytes': 'u1uptfvk09nqmf26h3vtved67enyxqezeknsa43cvafpmyfk5gkmszm36m8jpd2nvzu3u',
        'transparent only': 'u1522txr3xls2xdp2apcasepk2fze9f29ve2cyh2rcapy3cuav3am2hyq3zf893mr4gm8mhanwemkrhwam62lw58mcrlpgx4xyyj605f',
        'items out of order': 'u1mgjf45rapun8rxnaq0sqsev2wrce7frmn5jsdfth5nedufyuvk5ewkf0fgteq027ycuqs4pyxxrjnl59eavdlp7q3p7n7engtaqwxakagcx73d5v9w8uc8q30jsmk4w5xgkjewcuf6selu5zuet28nqfspuwv25vyzx6ngkg8gctxs6w',
        'wrong padding': 'u1twuxfemw6ee8t4lhzy3mtegcqsajh705g78pkc75gxa7wprleynnv9yrslwjp7dny33f4qvxvhcgmtzj8naxcrfgmapu8st3qygnshu0',
        'short Orchard receiver': 'u1cmvs0ljjkygms90tjkrhks93zfc9kcuwlhp4jt0l76t4qc7gk3tmkt8z8508ww2re57vj2uhgm9f3r8dr2ttr2lpryj3dqj2zpefvx',
        'uppercase': u1Orchard.toUpperCase(),
        'mixed case': 'U${u1Orchard.substring(1)}',
        'trailing space': '$u1Orchard ',
        'Solana key': fixtureRefund,
        'empty': '',
        'hrp only': 'u1',
        'bad charset': 'u1bio${u1Orchard.substring(5)}',
      };
      rejected.forEach((what, address) {
        expect(ZcashRoute.isUnifiedAddress(address), isFalse, reason: what);
      });
      expect(ZcashRoute.decodeUnifiedAddress(rejected['transparent only']!), (
        orchard: false,
        sapling: false,
        transparent: true,
      ));
    });

    test('quote rejects non-u1 destinations before any network call', () async {
      final r = Recorder();
      for (final dest in [
        't1Rv4exT7bqhZqi2j7xz8bUHDMxwosrjADU',
        'zs1mrhc9y7jdh5r9ece8u5khgvj9kg0zgkxzdduyv0whkg7lkcrkx5xqem3e48avjq9wn2rukydkwn',
        'u1uptfvk09nqmf26h3vtved67enyxqezeknsa43cvafpmyfk5gkmszm36m8jpd2nvzu3u',
        '${u1.substring(0, u1.length - 1)}q',
        fixtureRefund,
      ]) {
        await expectLater(
          route(r).quote(
            claimKey: fixtureRefund,
            inputMint: null,
            amount: 1000000000,
            destination: dest,
          ),
          throwsA(
            isA<ZcashRouteException>().having(
              (e) => e.message,
              'message',
              contains('unified address'),
            ),
          ),
        );
      }
      expect(r.requests, isEmpty);
    });
  });

  group('fee recipient', () {
    test('named or 64-hex NEAR accounts', () {
      for (final ok in [
        'deadman.near',
        'treasury.deadman.near',
        'dead_man-1.near',
        '5880ad2b362620fadf759cbceb1cd5737ce8c6ed7fb8e9942881e6731f9247dd',
      ]) {
        expect(ZcashRoute.isValidFeeRecipient(ok), isTrue, reason: ok);
      }
      for (final bad in [
        'a',
        'Deadman.near',
        'dead man.near',
        'deadman..near',
        '-deadman.near',
        'deadman.near.',
        'deadman@near',
        'x' * 65,
      ]) {
        expect(ZcashRoute.isValidFeeRecipient(bad), isFalse, reason: bad);
      }
    });

    test('defaults to the empty dart-define: no appFees', () {
      expect(zcashAppFeeRecipient, '');
      expect(ZcashRoute(client: Recorder().client).appFeeRecipient, '');
    });

    test('invalid recipient fails before any network call', () async {
      final r = Recorder();
      await expectLater(
        route(r, fee: 'Not A Near Account').quote(
          claimKey: fixtureRefund,
          inputMint: usdc,
          amount: 5000000,
          destination: u1,
        ),
        throwsA(
          isA<ZcashRouteException>().having(
            (e) => e.message,
            'message',
            contains('ZCASH_FEE_RECIPIENT'),
          ),
        ),
      );
      expect(r.requests, isEmpty);
    });

    test('sends appFees once a treasury is set', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      await route(r, fee: 'deadman.near').quote(
        claimKey: fixtureRefund,
        inputMint: usdc,
        amount: 5000000,
        destination: u1,
      );
      expect(body(r.requests.single)['appFees'], [
        {'recipient': 'deadman.near', 'fee': zcashAppFeeBps},
      ]);
    });
  });

  group('signature', () {
    test('verifies real dry and non-dry quotes', () async {
      for (final res in [dryQuoteSol, quoteUsdc, dryQuoteUsdt]) {
        expect(
          await ZcashRoute.verifyQuoteSignature(jsonDecode(res) as Map),
          isTrue,
        );
      }
    });

    test('rejects a swapped deposit address', () async {
      final res = jsonDecode(quoteUsdc) as Map;
      (res['quote'] as Map)['depositAddress'] = fixtureRefund;
      expect(await ZcashRoute.verifyQuoteSignature(res), isFalse);
    });

    test('rejects a changed amountOut', () async {
      final res = jsonDecode(dryQuoteUsdt) as Map;
      (res['quote'] as Map)['amountOut'] = '999999';
      expect(await ZcashRoute.verifyQuoteSignature(res), isFalse);
    });
  });

  group('quote', () {
    test('USDC: request fields and parsed quote', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      final q = await route(r).quote(
        claimKey: fixtureRefund,
        inputMint: usdc,
        amount: 5000000,
        destination: u1,
      );

      final sent = body(r.to('/v0/quote').single);
      expect(sent['dry'], false);
      expect(sent['swapType'], 'EXACT_INPUT');
      expect(
        sent['originAsset'],
        'nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near',
      );
      expect(sent['destinationAsset'], 'nep141:zec.omft.near');
      expect(sent['amount'], '5000000');
      expect(sent['refundTo'], fixtureRefund);
      expect(sent['refundType'], 'ORIGIN_CHAIN');
      expect(sent['recipient'], u1);
      expect(sent['recipientType'], 'DESTINATION_CHAIN');
      expect(sent['slippageTolerance'], 100);
      expect(sent['referral'], 'deadman');
      expect(sent.containsKey('appFees'), isFalse);
      expect(
        DateTime.parse(sent['deadline'] as String),
        quotedAt.add(const Duration(minutes: 30)),
      );

      expect(q.rail, Rail.zcash);
      expect(q.amountIn, 5000000);
      expect(q.inputMint, usdc);
      expect(q.depositAddress, 'E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg');
      expect(q.estimatedOut, '0.00340565 ZEC');
      expect(q.expiresAt, DateTime.utc(2026, 10, 2, 18, 59, 39));
    });

    test('USDT: maps the mint to its 1Click asset', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(dryQuoteUsdt, 201);
      final q = await route(r).estimate(
        claimKey: fixtureRefund,
        inputMint: usdt,
        amount: 5000000,
        destination: u1Orchard,
      );
      expect(
        body(r.requests.single)['originAsset'],
        'nep141:sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near',
      );
      expect(q.inputMint, usdt);
      expect(q.estimatedOut, '0.00343848 ZEC');
      expect(q.depositAddress, isNull);
    });

    test('dry estimate has no deposit address', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(dryQuoteSol, 201);
      final q = await route(r).estimate(
        claimKey: fixtureRefund,
        inputMint: null,
        amount: 1000000000,
        destination: u1,
      );
      expect(body(r.requests.single)['dry'], true);
      expect(body(r.requests.single)['originAsset'], 'nep141:sol.omft.near');
      expect(q.depositAddress, isNull);
      expect(q.estimatedOut, '0.08848584 ZEC');
    });

    test('rejects a tampered quote', () async {
      final res = jsonDecode(quoteUsdc) as Map;
      (res['quote'] as Map)['depositAddress'] = fixtureRefund;
      final r = Recorder()..handler = (_) async => json(res, 201);
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: usdc,
          amount: 5000000,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
    });

    test('rejects a quote for another refund key', () async {
      final other = (await Ed25519HDKeyPair.random()).address;
      final r = Recorder()
        ..handler = (_) async => http.Response(quoteUsdc, 201);
      await expectLater(
        route(r).quote(
          claimKey: other,
          inputMint: usdc,
          amount: 5000000,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
    });

    test('SOL below the rent minimum is refused locally', () async {
      final r = Recorder();
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: null,
          amount: ZcashRoute.rentExemptLamports - 1,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('unsupported mint', () async {
      final r = Recorder();
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: 'So11111111111111111111111111111111111111112',
          amount: 1,
          destination: u1,
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('surfaces the API error message', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'message': 'recipient is not valid',
          'correlationId': '21fcdb0a-34a1-4426-bf14-2e8d577cf670',
          'timestamp': '2026-10-02T18:27:52.211Z',
          'path': '/v0/quote',
        }, 400);
      await expectLater(
        route(r).quote(
          claimKey: fixtureRefund,
          inputMint: null,
          amount: 1000000000,
          destination: u1,
        ),
        throwsA(
          isA<ZcashRouteException>()
              .having((e) => e.message, 'message', 'recipient is not valid')
              .having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });
  });

  group('spendable', () {
    test('SOL: balance minus the transaction fee', () async {
      final r = Recorder()
        ..handler = (_) async => accounts([systemAccount(3000000)]);
      expect(
        await route(r).spendable(claimKey: fixtureRefund, inputMint: null),
        3000000 - ZcashRoute.txFeeLamports,
      );
      final params = r.rpcCalls('getMultipleAccounts').single['params'] as List;
      expect(params[0], [fixtureRefund]);
      expect((params[1] as Map)['encoding'], 'jsonParsed');
    });

    test('SOL: empty or missing account is 0', () async {
      final r = Recorder()..handler = (_) async => accounts([null]);
      expect(
        await route(r).spendable(claimKey: fixtureRefund, inputMint: null),
        0,
      );
      r.handler = (_) async => accounts([systemAccount(4000)]);
      expect(
        await route(r).spendable(claimKey: fixtureRefund, inputMint: null),
        0,
      );
    });

    test("token: the claim key's full ATA balance", () async {
      final r = Recorder()
        ..handler = (_) async => accounts([tokenAccount(7250000)]);
      expect(
        await route(r).spendable(claimKey: fixtureRefund, inputMint: usdc),
        7250000,
      );
      final ata = await findAssociatedTokenAddress(
        owner: Ed25519HDPublicKey.fromBase58(fixtureRefund),
        mint: Ed25519HDPublicKey.fromBase58(usdc),
      );
      expect((r.rpcCalls('getMultipleAccounts').single['params'] as List)[0], [
        ata.toBase58(),
      ]);
    });

    test('token: no ATA is 0', () async {
      final r = Recorder()..handler = (_) async => accounts([null]);
      expect(
        await route(r).spendable(claimKey: fixtureRefund, inputMint: usdt),
        0,
      );
    });

    test('rejects unsupported mints and bad keys locally', () async {
      final r = Recorder();
      await expectLater(
        route(r).spendable(claimKey: fixtureRefund, inputMint: 'nope'),
        throwsA(isA<ZcashRouteException>()),
      );
      await expectLater(
        route(r).spendable(claimKey: 'nope', inputMint: null),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });
  });

  group('execute', () {
    late Ed25519HDKeyPair claim;
    const deposit = 'E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg';
    const sig =
        '5ijsgRrhViNTtFMmnsfJDSo3HhRmt3Ri7WB513oBoQLxfGNswDxvHnakwW1yyqXznTTCSxnUkooAHDKowz9AjLkx';

    setUpAll(() async => claim = await Ed25519HDKeyPair.random());

    RouteQuote quoteFor(
      String? mint,
      int amount, {
      String? refundTo,
      String? originAsset,
    }) => RouteQuote(
      rail: Rail.zcash,
      amountIn: amount,
      inputMint: mint,
      estimatedOut: '0.1 ZEC',
      expiresAt: quotedAt.add(const Duration(minutes: 30)),
      depositAddress: deposit,
      raw: {
        'quoteRequest': {
          'refundTo': refundTo ?? claim.address,
          'originAsset': originAsset ?? ZcashRoute.inputs[mint]!.assetId,
        },
        'quote': {'depositAddress': deposit},
      },
    );

    /// [state] answers getMultipleAccounts: SOL route asks for the claim
    /// key; token route for claim key, its ATA and the deposit ATA.
    Recorder chain(List<Object?> state) => Recorder()
      ..handler = (req) async {
        if (req.url.toString() == rpc) {
          final m = body(req)['method'];
          if (m == 'getMultipleAccounts') return accounts(state);
          if (m == 'getLatestBlockhash') {
            return json({
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'context': {'slot': 1},
                'value': {
                  'blockhash': 'EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N',
                  'lastValidBlockHeight': 300,
                },
              },
            });
          }
          return json({'jsonrpc': '2.0', 'id': 1, 'result': sig});
        }
        return json(jsonDecode(statusPending));
      };

    Message sentMessage(Recorder r) {
      final send = r.rpcCalls('sendTransaction').single;
      final tx = SignedTx.decode((send['params'] as List).first as String);
      expect(tx.signatures.single.publicKey, claim.publicKey);
      return Message.decompile(tx.compiledMessage);
    }

    Matcher failsWith(String text) => throwsA(
      isA<ZcashRouteException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );

    test('SOL: system transfer of amountIn, then deposit/submit', () async {
      const amount = 123456789;
      final r = chain([systemAccount(amount + ZcashRoute.txFeeLamports)]);
      final id = await route(r)
          .execute(claimKey: claim, quote: quoteFor(null, amount));
      expect(id, deposit);

      expect((r.rpcCalls('getMultipleAccounts').single['params'] as List)[0], [
        claim.address,
      ]);
      final ix = sentMessage(r).instructions.single;
      expect(ix.programId.toBase58(), SystemProgram.programId);
      expect(ix.accounts[0].pubKey, claim.publicKey);
      expect(ix.accounts[1].pubKey.toBase58(), deposit);
      expect(
        ix.data.toList(),
        SystemInstruction.transfer(
          fundingAccount: claim.publicKey,
          recipientAccount: Ed25519HDPublicKey.fromBase58(deposit),
          lamports: amount,
        ).data.toList(),
      );

      final submit = r.to('/v0/deposit/submit').single;
      expect(submit.method, 'POST');
      expect(body(submit), {'txHash': sig, 'depositAddress': deposit});
    });

    test('SOL: keeps the fee and refuses to overspend', () async {
      final r = chain([systemAccount(1000000)]);
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(null, 1000000)),
        failsWith('needs 1005000'),
      );
      expect(r.rpcCalls('sendTransaction'), isEmpty);
    });

    test('SOL: refuses to leave rent-paying dust on the claim key', () async {
      final r = chain([systemAccount(2000000)]);
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(null, 1500000)),
        failsWith('rent minimum'),
      );
      expect(r.rpcCalls('sendTransaction'), isEmpty);
    });

    test('SOL: spendable() is exactly executable', () async {
      final r = chain([systemAccount(5000000)]);
      final z = route(r);
      final all = await z.spendable(claimKey: claim.address, inputMint: null);
      expect(
        await z.execute(claimKey: claim, quote: quoteFor(null, all)),
        deposit,
      );
    });

    for (final (symbol, mint) in [('USDC', usdc), ('USDT', usdt)]) {
      test('$symbol: create deposit ATA + transferChecked, fees from the '
          'stipend', () async {
        final r = chain([
          systemAccount(Limits.zcashGasStipend),
          tokenAccount(5000000),
          null,
        ]);
        await route(r).execute(claimKey: claim, quote: quoteFor(mint, 5000000));

        final mintKey = Ed25519HDPublicKey.fromBase58(mint);
        final depositAta = await findAssociatedTokenAddress(
          owner: Ed25519HDPublicKey.fromBase58(deposit),
          mint: mintKey,
        );
        final claimAta = await findAssociatedTokenAddress(
          owner: claim.publicKey,
          mint: mintKey,
        );
        expect(
          (r.rpcCalls('getMultipleAccounts').single['params'] as List)[0],
          [claim.address, claimAta.toBase58(), depositAta.toBase58()],
        );

        final message = sentMessage(r);
        final ixs = message.instructions;
        expect(ixs, hasLength(2));
        expect(
          ixs[0].programId.toBase58(),
          AssociatedTokenAccountProgram.programId,
        );
        expect(ixs[0].data.toList(), [1]);
        expect(ixs[0].accounts[0].pubKey, claim.publicKey);
        expect(ixs[0].accounts[1].pubKey, depositAta);
        expect(ixs[0].accounts[2].pubKey.toBase58(), deposit);
        expect(ixs[0].accounts[3].pubKey, mintKey);

        expect(ixs[1].programId.toBase58(), TokenProgram.programId);
        expect(ixs[1].accounts[0].pubKey, claimAta);
        expect(ixs[1].accounts[1].pubKey, mintKey);
        expect(ixs[1].accounts[2].pubKey, depositAta);
        expect(ixs[1].accounts[3].pubKey, claim.publicKey);
        expect(ixs[1].accounts[3].isSigner, isTrue);
        // transferChecked = 12, u64 LE amount, u8 decimals.
        expect(ixs[1].data.toList(), [12, 0x40, 0x4b, 0x4c, 0, 0, 0, 0, 0, 6]);
        expect(r.to('/v0/deposit/submit'), hasLength(1));
      });
    }

    test('USDC: existing deposit ATA needs only the fee', () async {
      final r = chain([
        systemAccount(ZcashRoute.rentExemptLamports + 5000),
        tokenAccount(5000000),
        tokenAccount(0),
      ]);
      await route(r).execute(claimKey: claim, quote: quoteFor(usdc, 5000000));
      expect(r.rpcCalls('sendTransaction'), hasLength(1));
    });

    test('USDC: clear error when the claim key lacks SOL for fees', () async {
      final r = chain([systemAccount(1000000), tokenAccount(5000000), null]);
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(usdc, 5000000)),
        failsWith('lacks SOL for fees: has 1000000 lamports, needs 2044280'),
      );
      expect(r.rpcCalls('sendTransaction'), isEmpty);
      expect(r.to('/v0/deposit/submit'), isEmpty);
    });

    test('USDC: no SOL at all', () async {
      final r = chain([null, tokenAccount(5000000), null]);
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(usdc, 5000000)),
        failsWith('lacks SOL for fees'),
      );
    });

    test('USDC: refuses more than the claim key holds', () async {
      final r = chain([
        systemAccount(Limits.zcashGasStipend),
        tokenAccount(4999999),
        null,
      ]);
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(usdc, 5000000)),
        failsWith('holds 4999999'),
      );
      expect(r.rpcCalls('sendTransaction'), isEmpty);
    });

    test('refuses a quote for another asset', () async {
      final r = chain([
        systemAccount(Limits.zcashGasStipend),
        tokenAccount(5000000),
        null,
      ]);
      await expectLater(
        route(r).execute(
          claimKey: claim,
          quote: quoteFor(usdc, 5000000, originAsset: 'nep141:sol.omft.near'),
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('deposit/submit failure does not fail the payout', () async {
      final r = chain([systemAccount(1000000 + 5000)]);
      final base = r.handler;
      r.handler = (req) async => req.url.path == '/v0/deposit/submit'
          ? json({'message': 'boom'}, 500)
          : base(req);
      expect(
        await route(r).execute(claimKey: claim, quote: quoteFor(null, 1000000)),
        deposit,
      );
    });

    test('deposit/submit network error does not fail the payout', () async {
      final r = chain([systemAccount(1000000 + 5000)]);
      final base = r.handler;
      r.handler = (req) async => req.url.path == '/v0/deposit/submit'
          ? throw http.ClientException('offline')
          : base(req);
      expect(
        await route(r).execute(claimKey: claim, quote: quoteFor(null, 1000000)),
        deposit,
      );
    });

    test('refuses a quote that refunds elsewhere', () async {
      final r = chain([]);
      await expectLater(
        route(r).execute(
          claimKey: claim,
          quote: quoteFor(null, 1, refundTo: fixtureRefund),
        ),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('refuses an expired quote', () async {
      final r = chain([]);
      final late = ZcashRoute(
        client: r.client,
        cluster: 'mainnet-beta',
        rpcUrl: rpc,
        now: () => quotedAt.add(const Duration(hours: 1)),
      );
      await expectLater(
        late.execute(claimKey: claim, quote: quoteFor(null, 1)),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('refuses off mainnet', () async {
      final r = chain([]);
      await expectLater(
        route(
          r,
          cluster: 'devnet',
        ).execute(claimKey: claim, quote: quoteFor(null, 1000000)),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.requests, isEmpty);
    });

    test('RPC error propagates', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32002, 'message': 'insufficient funds'},
        });
      await expectLater(
        route(r).execute(claimKey: claim, quote: quoteFor(null, 1)),
        throwsA(isA<ZcashRouteException>()),
      );
      expect(r.to('/v0/deposit/submit'), isEmpty);
    });
  });

  group('status', () {
    test('polls by deposit address', () async {
      final r = Recorder()
        ..handler = (_) async => http.Response(statusPending, 200);
      expect(
        await route(r).status('E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg'),
        'PENDING_DEPOSIT',
      );
      final req = r.requests.single;
      expect(req.method, 'GET');
      expect(
        req.url.toString(),
        'https://1click.chaindefuser.com/v0/status?depositAddress=E5RdW4ip1B4wx1Loy83zr2dVadYywJazHvB22JBKq1Dg',
      );
    });

    test('unknown deposit address throws 404', () async {
      final r = Recorder()
        ..handler = (_) async => json({
          'message': 'Deposit address x not found',
          'error': 'Not Found',
          'statusCode': 404,
        }, 404);
      await expectLater(
        route(r).status('x'),
        throwsA(
          isA<ZcashRouteException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });

  group('track', () {
    Recorder replay(List<Object> script) {
      var i = 0;
      return Recorder()
        ..handler = (_) async {
          final next = script[i++];
          if (next is http.Response) return next;
          if (next is Exception) throw next;
          return json({'status': next});
        };
    }

    test('emits changes until SUCCESS, backing off while idle', () async {
      final sleeps = <Duration>[];
      final r = replay([
        'PENDING_DEPOSIT',
        'PENDING_DEPOSIT',
        'PENDING_DEPOSIT',
        'KNOWN_DEPOSIT_TX',
        json({'message': 'busy'}, 503),
        http.ClientException('reset'),
        json({'message': 'slow down'}, 429),
        'PROCESSING',
        'SUCCESS',
      ]);
      final seen = await route(
        r,
        sleeps: sleeps,
      ).track('dep', every: const Duration(seconds: 2)).toList();
      expect(seen, [
        'PENDING_DEPOSIT',
        'KNOWN_DEPOSIT_TX',
        'PROCESSING',
        'SUCCESS',
      ]);
      expect(sleeps.map((d) => d.inSeconds), [2, 4, 8, 2, 4, 8, 16, 2]);
      expect(r.requests, hasLength(9));
      expect(r.requests.first.url.queryParameters['depositAddress'], 'dep');
    });

    test('caps the backoff', () async {
      final sleeps = <Duration>[];
      final r = replay([...List.filled(6, 'PROCESSING'), 'REFUNDED']);
      await route(r, sleeps: sleeps)
          .track(
            'dep',
            every: const Duration(seconds: 10),
            maxEvery: const Duration(seconds: 30),
          )
          .drain<void>();
      expect(sleeps.map((d) => d.inSeconds), [10, 20, 30, 30, 30, 30]);
    });

    for (final terminal in ZcashRoute.terminalStatuses) {
      test('stops at $terminal', () async {
        final sleeps = <Duration>[];
        final r = replay([terminal, 'PROCESSING']);
        expect(await route(r, sleeps: sleeps).track('dep').toList(), [
          terminal,
        ]);
        expect(r.requests, hasLength(1));
        expect(sleeps, isEmpty);
      });
    }

    test('a 404 ends the stream with the error', () async {
      final r = replay([
        json({'message': 'Deposit address dep not found'}, 404),
      ]);
      await expectLater(
        route(r, sleeps: []).track('dep'),
        emitsError(
          isA<ZcashRouteException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });
}
