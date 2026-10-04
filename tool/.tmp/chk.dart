import 'package:deadman/solana/deadman_client.dart';
Future<void> main() async {
  final c = DeadmanClient.withKora();
  const owner = 'AppAYe7kXr8uqApxshXvV9CNEka3AZtBwNgX4NBK9PbA';
  for (final v in await c.fetchVaults(owner)) {
    print('#${v.planId} "${v.label}" vault=${v.address} sol=${v.withdrawableLamports} interval=${v.intervalSecs} grace=${v.skipGraceSecs}');
    for (final r in v.rules) {
      print('   rule ${r.mint} ${r.mode.name} ${r.amount} after=${r.afterSecs} rail=${r.rail.name} ben=${r.beneficiary} exec=${r.executedAt} skip=${r.skippedAt}');
    }
    for (final m in ['Ew8Z6hhRp7MFK8KJAxRqaBQvBEjtRj4Y4K4YhWsPMFGk', '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU']) {
      print('   vault holds $m: ${await c.tokenBalance(v.address, m)}');
    }
  }
}
