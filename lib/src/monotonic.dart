import 'package:clock/clock.dart';

/// Starts a stopwatch that ignores device time changes.
///
/// `clock.stopwatch()` from `package:clock` measures elapsed time with
/// `clock.now()`, which is the device wall clock in production, so a user
/// changing the device time would move it. A plain [Stopwatch] reads the OS
/// monotonic clock instead. The `package:clock` stopwatch is used only when a
/// test has replaced the clock (for example with `fake_async`).
Stopwatch startMonotonicStopwatch() {
  final current = clock;
  final stopwatch =
      identical(current, const Clock()) ? Stopwatch() : current.stopwatch();
  return stopwatch..start();
}
