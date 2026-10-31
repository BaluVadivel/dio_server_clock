import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:dio_server_clock/src/monotonic.dart';
import 'package:test/test.dart';

import 'fake_source.dart';

const _ms = Duration(milliseconds: 1);
const _s = Duration(seconds: 1);

void main() {
  final server = DateTime.utc(2026, 10, 30, 20);
  late FakeSource source;

  setUp(() => monotonicSourceOverride = source = FakeSource());
  tearDown(() => monotonicSourceOverride = null);

  group('no time', () {
    test('a new clock has no time and reports nothing', () {
      final c = ServerClock();
      expect(c.now, isNull);
      expect(c.nowIn(const Duration(hours: 5)), isNull);
      expect(c.isSynced, isFalse);
      expect(c.deviceSkew, isNull);
      expect(c.uncertainty, isNull);
    });

    test('reset clears the time', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      c.reset();
      expect(c.now, isNull);
      expect(c.uncertainty, isNull);
      expect(c.addSample(server, _s * 5), isTrue, reason: 'loose limit');
    });

    test('a monotonic clock that fails gives no time', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      source.micros = null;
      expect(c.now, isNull);
      expect(c.isSynced, isFalse);
      expect(c.addSample(server, Duration.zero), isFalse);
    });

    test('a monotonic clock that goes backwards gives no time', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      source.micros = source.micros! - 1;
      expect(c.now, isNull);
    });
  });

  group('anchoring', () {
    test('adds half the round trip and advances with the monotonic clock', () {
      final c = ServerClock();
      expect(c.addSample(server, _ms * 200), isTrue);
      expect(c.now, server.add(_ms * 100));
      source.advance(const Duration(minutes: 3));
      expect(c.now, server.add(const Duration(minutes: 3) + _ms * 100));
      expect(c.now!.isUtc, isTrue);
      expect(c.uncertainty, _ms * 100);
    });

    test('HTTP dates are centred in their one-second window', () {
      final c = ServerClock();
      expect(c.addHttpDate('Fri, 30 Oct 2026 20:00:00 GMT', _ms * 200), true);
      expect(c.now, server.add(_ms * 600));
      expect(c.uncertainty, _ms * 600);
    });

    test('accepts all HTTP date formats and surrounding spaces', () {
      for (final date in [
        '  Fri, 30 Oct 2026 20:00:00 GMT ',
        'Friday, 30-Oct-26 20:00:00 GMT',
        'Fri Oct 30 20:00:00 2026',
      ]) {
        final c = ServerClock();
        expect(c.addHttpDate(date, Duration.zero), isTrue, reason: date);
        expect(c.now, server.add(_ms * 500), reason: date);
      }
    });

    test('two-digit years are at most 50 years in the future', () {
      withClock(Clock.fixed(server), () {
        final c =
            ServerClock()
              ..addHttpDate('Friday, 30-Oct-99 20:00:00 GMT', Duration.zero);
        expect(c.now!.year, 1999);
        final d =
            ServerClock()
              ..addHttpDate('Friday, 30-Oct-75 20:00:00 GMT', Duration.zero);
        expect(d.now!.year, 2075);
      });
    });

    test('rejects invalid HTTP dates without throwing', () {
      final c = ServerClock();
      for (final date in ['', 'nonsense', '2026-10-30T20:00:00Z']) {
        expect(c.addHttpDate(date, Duration.zero), isFalse, reason: date);
      }
      expect(c.now, isNull);
    });

    test('rejects negative round trips and resolutions', () {
      final c = ServerClock();
      expect(c.addSample(server, -_ms), isFalse);
      expect(c.addSample(server, Duration.zero, resolution: -_ms), isFalse);
      expect(c.now, isNull);
    });

    test('reports device skew; positive when the device is behind', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      withClock(Clock.fixed(server.add(const Duration(minutes: 10))), () {
        expect(c.deviceSkew, const Duration(minutes: -10));
      });
      withClock(Clock.fixed(server.subtract(const Duration(minutes: 2))), () {
        expect(c.deviceSkew, const Duration(minutes: 2));
      });
    });

    test('the device clock is never used for the time', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      withClock(Clock.fixed(DateTime.utc(2000)), () {
        expect(c.now, server);
      });
    });

    test('nowIn applies a fixed offset to the fields', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      final ist = c.nowIn(const Duration(hours: 5, minutes: 30))!;
      expect([ist.day, ist.hour, ist.minute], [31, 1, 30]);
      expect(ist.weekday, DateTime.saturday);
    });
  });

  group('choosing samples', () {
    test('uses the loose limit without a time and the strict one with', () {
      final c = ServerClock();
      expect(c.addSample(server, _s * 11), isFalse);
      expect(c.addSample(server, _s * 10), isTrue);
      expect(c.addSample(server, _s * 3), isFalse);
      expect(c.addSample(server, _s * 2), isTrue);
    });

    test('the newest sample wins, even a less precise one', () {
      final c = ServerClock()..addSample(server, _ms * 100);
      source.advance(_s * 30);
      final later = server.add(_s * 31);
      expect(c.addSample(later, _ms * 1800), isTrue);
      expect(c.now, later.add(_ms * 900));
      expect(c.uncertainty, _ms * 900);
    });

    test('a sample far ahead replaces a stale time at once', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      // For example, sleep the monotonic clock didn't count.
      final real = server.add(const Duration(hours: 1));
      expect(c.addSample(real, Duration.zero), isTrue);
      expect(c.now, real);
    });

    test('a sample far behind (a cached copy) is ignored', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      final old = server.subtract(const Duration(hours: 2));
      expect(c.addSample(old, Duration.zero), isFalse);
      expect(c.now, server);
    });

    test('a sample behind within tolerance is accepted', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      expect(c.addSample(server.subtract(_s * 4), Duration.zero), isTrue);
    });

    test('the same cached copy seen repeatedly is never accepted', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      final old = server.subtract(const Duration(hours: 2));
      for (var i = 0; i < 6; i++) {
        source.advance(_s * 10);
        expect(c.addSample(old, Duration.zero), isFalse, reason: '$i');
      }
    });

    test(
      'three agreeing samples behind are accepted: the server moved back',
      () {
        final c = ServerClock()..addSample(server, Duration.zero);
        final back = server.subtract(const Duration(minutes: 10));
        expect(c.addSample(back, Duration.zero), isFalse);
        source.advance(_s * 6);
        expect(c.addSample(back.add(_s * 6), Duration.zero), isFalse);
        source.advance(_s * 6);
        expect(c.addSample(back.add(_s * 12), Duration.zero), isTrue);
        expect(c.now, back.add(_s * 12));
      },
    );

    test('agreeing samples behind within a short span are not enough', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      final back = server.subtract(const Duration(minutes: 10));
      for (var i = 0; i < 3; i++) {
        source.advance(_s * 2);
        expect(
          c.addSample(back.add(_s * 2 * (i + 1)), Duration.zero),
          isFalse,
          reason: '$i',
        );
      }
    });

    test('an accepted sample resets the behind count', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      final back = server.subtract(const Duration(minutes: 10));
      expect(c.addSample(back, Duration.zero), isFalse);
      source.advance(_s * 6);
      expect(c.addSample(back.add(_s * 6), Duration.zero), isFalse);
      expect(c.addSample(server.add(_s * 6), Duration.zero), isTrue);
      source.advance(_s * 6);
      expect(c.addSample(back.add(_s * 12), Duration.zero), isFalse);
    });

    test('custom limits are respected', () {
      final c = ServerClock(
        maxRoundTrip: _ms * 500,
        maxRoundTripBeforeSync: _s,
        tolerance: _s * 30,
      );
      expect(c.addSample(server, _ms * 1001), isFalse);
      expect(c.addSample(server, _ms * 100), isTrue);
      expect(c.addSample(server, _ms * 600), isFalse);
      expect(c.addSample(server.subtract(_s * 20), Duration.zero), isTrue);
    });

    test('negative limits throw', () {
      expect(() => ServerClock(maxRoundTrip: -_ms), throwsArgumentError);
      expect(
        () => ServerClock(maxRoundTripBeforeSync: -_ms),
        throwsArgumentError,
      );
      expect(() => ServerClock(tolerance: -_ms), throwsArgumentError);
    });
  });

  group('invalidate (app resumed)', () {
    test('keeps the time where sleep is counted', () {
      final c = ServerClock()..addSample(server, Duration.zero);
      expect(c.countsSleep, isTrue);
      source.advance(const Duration(hours: 1)); // asleep
      c.invalidate();
      expect(c.now, server.add(const Duration(hours: 1)));
    });

    test('clears the time where sleep may not be counted', () async {
      monotonicSourceOverride = source = FakeSource(countsSleep: false);
      final c = ServerClock();
      final changes = <bool>[];
      c.onSyncChanged.listen(changes.add);
      c.addSample(server, Duration.zero);
      expect(c.countsSleep, isFalse);
      c.invalidate();
      expect(c.now, isNull);
      // The next sample gets the loose limit.
      expect(c.addSample(server, _s * 5), isTrue);
      await pumpEventQueue();
      expect(changes, [true, false, true]);
    });

    test('does nothing without a time', () {
      final c = ServerClock()..invalidate();
      expect(c.now, isNull);
    });
  });

  group('streams', () {
    test('onAnchor emits accepted samples, not rejected ones', () async {
      final c = ServerClock();
      final samples = <ClockSample>[];
      c.onAnchor.listen(samples.add);
      await withClock(
        Clock.fixed(server.add(const Duration(minutes: 1, milliseconds: 100))),
        () async {
          c.addSample(server, _ms * 200);
          c.addSample(server, _s * 9);
          await pumpEventQueue();
        },
      );
      expect(samples, hasLength(1));
      expect(samples.single.serverTime, server.add(_ms * 100));
      expect(samples.single.roundTrip, _ms * 200);
      expect(samples.single.uncertainty, _ms * 100);
      expect(samples.single.deviceSkew, const Duration(minutes: -1));
    });

    test('onSyncChanged emits on gaining and losing the time only', () async {
      final c = ServerClock();
      final changes = <bool>[];
      c.onSyncChanged.listen(changes.add);
      c
        ..addSample(server, Duration.zero)
        ..addSample(server, Duration.zero)
        ..reset()
        ..reset()
        ..addSample(server, Duration.zero);
      await pumpEventQueue();
      expect(changes, [true, false, true]);
    });

    test('the clock keeps working after dispose', () async {
      final c = ServerClock();
      await c.dispose();
      await c.dispose();
      expect(c.addSample(server, Duration.zero), isTrue);
      c.reset();
      expect(c.now, isNull);
    });
  });

  group('platform monotonic source', () {
    setUp(() => monotonicSourceOverride = null);

    test('counts sleep on Android, iOS, macOS and Linux', () async {
      final source = resolveMonotonicSource();
      final bootClock =
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux;
      expect(source.countsSleep, bootClock);
      if (bootClock) expect(source, isNot(isA<StopwatchSource>()));

      // Tracks real elapsed time.
      final stopwatch = Stopwatch()..start();
      final start = source.nowMicros()!;
      await Future<void>.delayed(_ms * 200);
      final elapsed = source.nowMicros()! - start;
      expect(
        (elapsed - stopwatch.elapsedMicroseconds).abs(),
        lessThan(20000),
        reason: 'elapsed $elapsed us',
      );
    });

    test('is shared, and ignores device time changes', () {
      final source = resolveMonotonicSource();
      expect(identical(source, resolveMonotonicSource()), isTrue);
      final before = source.nowMicros()!;
      // A different device time doesn't move it.
      final during = withClock(
        Clock.fixed(DateTime.utc(2000)),
        () => source.nowMicros()!,
      );
      expect(during - before, inInclusiveRange(0, 100000));
    });

    test('follows a test clock when one is installed', () {
      withClock(Clock.fixed(server), () {
        final source = resolveMonotonicSource();
        expect(source.nowMicros(), server.microsecondsSinceEpoch);
      });
    });

    test('a stopwatch source does not count sleep', () {
      final source = StopwatchSource();
      expect(source.countsSleep, isFalse);
      expect(source.nowMicros(), greaterThanOrEqualTo(0));
    });
  });
}
