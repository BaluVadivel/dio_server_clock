import 'package:clock/clock.dart';

import 'monotonic_stub.dart' if (dart.library.ffi) 'monotonic_ffi.dart';

/// A clock that only moves forward and that the user can't change.
abstract class MonotonicSource {
  /// Whether the clock keeps counting while the device is in deep sleep.
  bool get countsSleep;

  /// Microseconds since an arbitrary fixed point, or null if the clock can't
  /// be read.
  int? nowMicros();
}

/// Replaces the source chosen by [resolveMonotonicSource]. For tests only.
MonotonicSource? monotonicSourceOverride;

/// The source a new `ServerClock` uses.
///
/// - [monotonicSourceOverride] when set (tests).
/// - A `package:clock` source when a test has replaced the clock (for example
///   with `fake_async`). It counts sleep.
/// - Otherwise the platform boot clock, which counts deep sleep (Android,
///   iOS, macOS, Linux), or a [Stopwatch] where that is unavailable (web,
///   Windows, or any error), which may pause during deep sleep.
///
/// `clock.stopwatch()` from `package:clock` is never used: it measures time
/// with `clock.now()`, the device wall clock, which the user can change.
MonotonicSource resolveMonotonicSource() {
  final override = monotonicSourceOverride;
  if (override != null) return override;
  if (!identical(clock, const Clock())) return _ClockSource();
  return _platformSource ??= _createPlatformSource();
}

MonotonicSource? _platformSource;

MonotonicSource _createPlatformSource() {
  try {
    final boot = createBootClock();
    if (boot != null && _works(boot)) return boot;
  } catch (_) {
    // Fall through to the stopwatch.
  }
  return StopwatchSource();
}

/// Two readings that are present and don't go backwards.
bool _works(MonotonicSource source) {
  final first = source.nowMicros();
  final second = source.nowMicros();
  return first != null && second != null && first > 0 && second >= first;
}

/// Reads the OS monotonic clock through [Stopwatch]; may pause in deep sleep.
class StopwatchSource implements MonotonicSource {
  final _stopwatch = Stopwatch()..start();

  @override
  bool get countsSleep => false;

  @override
  int? nowMicros() => _stopwatch.elapsedMicroseconds;
}

/// Follows a `package:clock` clock installed by a test.
class _ClockSource implements MonotonicSource {
  @override
  bool get countsSleep => true;

  @override
  int? nowMicros() => clock.now().microsecondsSinceEpoch;
}
