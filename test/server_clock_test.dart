import 'package:clock/clock.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:dio_server_clock/src/monotonic.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

const _ms = Duration(milliseconds: 1);

void main() {
  final server = DateTime.utc(2026, 10, 30, 20);

  group('before the first sample', () {
    test('falls back to device time and reports nothing', () {
      final device = DateTime.utc(2026, 1, 1, 12);
      fakeAsync((async) {
        final c = ServerClock();
        expect(c.isSynced, isFalse);
        expect(c.now, device);
        expect(c.now.isUtc, isTrue);
        expect(c.deviceSkew, isNull);
        expect(c.uncertainty, isNull);
      }, initialTime: device);
    });

    test('invalidate does nothing', () {
      fakeAsync((async) {
        final c = ServerClock()..invalidate();
        expect(c.isSynced, isFalse);
        expect(c.addSample(server, const Duration(seconds: 5)), isTrue);
        // The clock is synced now, so the strict limit applies.
        expect(c.addSample(server, const Duration(seconds: 3)), isFalse);
      });
    });
  });

  group('anchoring', () {
    test('adds half the round trip and advances with elapsed time', () {
      fakeAsync((async) {
        final c = ServerClock();
        expect(c.addSample(server, _ms * 200), isTrue);
        expect(c.now, server.add(_ms * 100));
        async.elapse(const Duration(minutes: 3));
        expect(c.now, server.add(const Duration(minutes: 3) + _ms * 100));
        expect(c.uncertainty, _ms * 100);
      });
    });

    test('HTTP dates are centred in their one-second window', () {
      fakeAsync((async) {
        final c = ServerClock();
        expect(c.addHttpDate('Fri, 30 Oct 2026 20:00:00 GMT', _ms * 200), true);
        expect(c.now, server.add(_ms * 600));
        expect(c.uncertainty, _ms * 600);
      });
    });

    test('accepts all HTTP date formats and surrounding spaces', () {
      fakeAsync((async) {
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
    });

    test('two-digit years are at most 50 years in the future', () {
      fakeAsync((async) {
        final c =
            ServerClock()
              ..addHttpDate('Friday, 30-Oct-99 20:00:00 GMT', Duration.zero);
        expect(c.now.year, 1999);
        final d =
            ServerClock()
              ..addHttpDate('Friday, 30-Oct-75 20:00:00 GMT', Duration.zero);
        expect(d.now.year, 2075);
      }, initialTime: server);
    });

    test('rejects invalid HTTP dates without throwing', () {
      fakeAsync((async) {
        final c = ServerClock();
        for (final date in ['', 'nonsense', '2026-10-30T20:00:00Z']) {
          expect(c.addHttpDate(date, Duration.zero), isFalse, reason: date);
        }
        expect(c.isSynced, isFalse);
      });
    });

    test('rejects negative round trips and resolutions', () {
      fakeAsync((async) {
        final c = ServerClock();
        expect(c.addSample(server, -_ms), isFalse);
        expect(c.addSample(server, Duration.zero, resolution: -_ms), isFalse);
        expect(c.isSynced, isFalse);
      });
    });

    test('reports device skew; positive when the device is behind', () {
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, Duration.zero);
        expect(c.deviceSkew, const Duration(minutes: -10));
      }, initialTime: server.add(const Duration(minutes: 10)));

      fakeAsync((async) {
        final c = ServerClock()..addSample(server, Duration.zero);
        expect(c.deviceSkew, const Duration(minutes: 2));
      }, initialTime: server.subtract(const Duration(minutes: 2)));
    });

    test('nowIn applies a fixed offset to the fields', () {
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, Duration.zero);
        final ist = c.nowIn(const Duration(hours: 5, minutes: 30));
        expect([ist.day, ist.hour, ist.minute], [31, 1, 30]);
        expect(ist.weekday, DateTime.saturday);
      });
    });
  });

  group('choosing samples', () {
    test('uses the loose limit before sync and the strict one after', () {
      fakeAsync((async) {
        final c = ServerClock();
        expect(c.addSample(server, const Duration(seconds: 11)), isFalse);
        expect(c.addSample(server, const Duration(seconds: 10)), isTrue);
        expect(c.addSample(server, const Duration(seconds: 3)), isFalse);
        expect(c.addSample(server, const Duration(seconds: 2)), isTrue);
      });
    });

    test('keeps the more precise anchor until it is old', () {
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, _ms * 100);
        expect(c.addSample(server, _ms * 500), isFalse);
        expect(c.addSample(server, _ms * 100), isFalse, reason: 'not better');
        async.elapse(const Duration(minutes: 6));
        // An old anchor is still replaced only within the strict limit.
        expect(c.addSample(server, const Duration(seconds: 3)), isFalse);
        expect(c.addSample(server, _ms * 500), isTrue);
        expect(c.uncertainty, _ms * 250);
      });
    });

    test('a more precise sample replaces the anchor at once', () {
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, _ms * 800);
        final later = server.add(const Duration(seconds: 30));
        expect(c.addSample(later, _ms * 100), isTrue);
        expect(c.now, later.add(_ms * 50));
      });
    });

    test('invalidate: next sample replaces, with the loose limit', () {
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, _ms * 100);
        c.invalidate();
        // The anchor keeps working until a sample arrives.
        expect(c.isSynced, isTrue);
        expect(c.uncertainty, _ms * 50);
        expect(c.addSample(server, const Duration(seconds: 5)), isTrue);
        // Back to normal selection afterwards.
        expect(c.addSample(server, const Duration(seconds: 3)), isFalse);
      });
    });

    test('reset forgets the anchor', () {
      final device = DateTime.utc(2026, 1, 1);
      fakeAsync((async) {
        final c = ServerClock()..addSample(server, Duration.zero);
        c.reset();
        expect(c.isSynced, isFalse);
        expect(c.uncertainty, isNull);
        expect(c.now, device);
        expect(c.addSample(server, const Duration(seconds: 5)), isTrue);
      }, initialTime: device);
    });

    test('custom limits are respected', () {
      fakeAsync((async) {
        final c = ServerClock(
          maxRoundTrip: _ms * 500,
          maxRoundTripBeforeSync: const Duration(seconds: 1),
          maxAnchorAge: const Duration(seconds: 10),
        );
        expect(c.addSample(server, _ms * 1001), isFalse);
        expect(c.addSample(server, _ms * 100), isTrue);
        async.elapse(const Duration(seconds: 11));
        expect(c.addSample(server, _ms * 600), isFalse);
        expect(c.addSample(server, _ms * 400), isTrue);
      });
    });

    test('negative limits throw', () {
      expect(() => ServerClock(maxRoundTrip: -_ms), throwsArgumentError);
      expect(
        () => ServerClock(maxRoundTripBeforeSync: -_ms),
        throwsArgumentError,
      );
      expect(() => ServerClock(maxAnchorAge: -_ms), throwsArgumentError);
    });
  });

  group('onAnchor', () {
    test('emits each new anchor, not rejected samples', () {
      fakeAsync(
        (async) {
          final c = ServerClock();
          final samples = <ClockSample>[];
          c.onAnchor.listen(samples.add);
          c.addSample(server, _ms * 200);
          c.addSample(server, _ms * 900);
          async.flushMicrotasks();
          expect(samples, hasLength(1));
          expect(samples.single.serverTime, server.add(_ms * 100));
          expect(samples.single.roundTrip, _ms * 200);
          expect(samples.single.uncertainty, _ms * 100);
          expect(samples.single.deviceSkew, const Duration(minutes: -1));
        },
        initialTime: server.add(const Duration(minutes: 1, milliseconds: 100)),
      );
    });

    test('the clock keeps working after dispose', () async {
      final c = ServerClock();
      await c.dispose();
      await c.dispose();
      expect(c.addSample(server, Duration.zero), isTrue);
      expect(c.isSynced, isTrue);
    });
  });

  group('monotonic stopwatch', () {
    test('uses the OS monotonic clock, not the device time', () {
      // clock.stopwatch() would follow clock.now(), the device wall clock.
      final stopwatch = startMonotonicStopwatch();
      expect(stopwatch.runtimeType, Stopwatch().runtimeType);
      expect(stopwatch.isRunning, isTrue);
    });

    test('follows a test clock when one is installed', () {
      withClock(Clock.fixed(server), () {
        final stopwatch = startMonotonicStopwatch();
        expect(stopwatch.runtimeType, isNot(Stopwatch().runtimeType));
      });
    });
  });
}
