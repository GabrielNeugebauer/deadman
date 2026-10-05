import 'package:deadman/state/reminder_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const day = 86400;

  group('reminderLeads', () {
    test('days-long waits: 3 days, 1 day, 1 hour, then at the release', () {
      expect(reminderLeads(30 * day), [3 * day, day, 3600, 0]);
      expect(reminderLeads(6 * day), [3 * day, day, 3600, 0]);
    });

    test('a lead is kept only while it is at most half the wait', () {
      expect(reminderLeads(3 * day), [day, 3600, 0]);
      expect(reminderLeads(day), [3600, 0]);
    });

    test('demo waits scale down to half the wait', () {
      expect(reminderLeads(120), [60, 0]);
      expect(reminderLeads(600), [300, 0]);
    });
  });

  group('reminderLead', () {
    const release = 100 * day;

    test('nothing before the first lead', () {
      expect(
        reminderLead(
          now: release - 4 * day,
          releaseAt: release,
          delaySecs: 30 * day,
        ),
        isNull,
      );
    });

    test('the latest lead reached', () {
      int? at(int now) =>
          reminderLead(now: now, releaseAt: release, delaySecs: 30 * day);
      expect(at(release - 3 * day), 3 * day);
      expect(at(release - 2 * day), 3 * day);
      expect(at(release - day + 1), day);
      expect(at(release - 60), 3600);
      expect(at(release), 0);
      expect(at(release + 5 * day), 0);
    });
  });

  test('reminder copy counts down to the release, then says it is due', () {
    expect(reminderText(3 * day).$1, 'Time to check in');
    expect(reminderText(3 * day).$2, contains('releases in 3 days'));
    expect(reminderText(3600).$2, contains('releases in 1 hour'));
    expect(reminderText(90).$2, contains('releases in 1 minute'));
    expect(reminderText(0).$1, 'A payout is due');
    expect(reminderText(-5).$1, 'A payout is due');
  });
}
