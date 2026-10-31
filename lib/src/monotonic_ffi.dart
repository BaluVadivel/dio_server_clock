import 'dart:ffi';
import 'dart:io' show Platform;

import 'monotonic.dart';

/// The platform's boot clock, which keeps counting through deep sleep and
/// can't be changed by the user, or null on platforms without one here.
///
/// - Android and Linux: `clock_gettime(CLOCK_BOOTTIME)`.
/// - iOS and macOS: `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which on Apple
///   platforms counts sleep (unlike `CLOCK_UPTIME_RAW`).
///
/// Throws if a symbol can't be found; the caller falls back to a stopwatch.
MonotonicSource? createBootClock() {
  if (Platform.isIOS || Platform.isMacOS) return _DarwinBootClock();
  if (Platform.isAndroid || Platform.isLinux) return _LinuxBootClock();
  return null;
}

const _darwinClockMonotonic = 6;
const _linuxClockBoottime = 7;

class _DarwinBootClock implements MonotonicSource {
  _DarwinBootClock()
    : _nanos = DynamicLibrary.process()
          .lookupFunction<Uint64 Function(Int32), int Function(int)>(
            'clock_gettime_nsec_np',
          );

  final int Function(int clockId) _nanos;

  @override
  bool get countsSleep => true;

  @override
  int? nowMicros() {
    // Returns 0 on failure.
    final nanos = _nanos(_darwinClockMonotonic);
    return nanos <= 0 ? null : nanos ~/ 1000;
  }
}

/// `struct timespec`: `time_t` and `long` are both `long` on Linux and
/// Android, so 32 bits on 32-bit devices and 64 bits on 64-bit ones.
final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}

class _LinuxBootClock implements MonotonicSource {
  factory _LinuxBootClock() {
    final libc = _libc();
    final clockGettime = libc.lookupFunction<
      Int32 Function(Int32, Pointer<_Timespec>),
      int Function(int, Pointer<_Timespec>)
    >('clock_gettime');
    final malloc = libc.lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)
    >('malloc');
    // Allocated once and reused for the life of the process.
    final buffer = malloc(sizeOf<_Timespec>()).cast<_Timespec>();
    if (buffer == nullptr) throw StateError('malloc failed');
    return _LinuxBootClock._(clockGettime, buffer);
  }

  _LinuxBootClock._(this._clockGettime, this._buffer);

  final int Function(int clockId, Pointer<_Timespec> time) _clockGettime;
  final Pointer<_Timespec> _buffer;

  static DynamicLibrary _libc() {
    final process = DynamicLibrary.process();
    if (process.providesSymbol('clock_gettime')) return process;
    return DynamicLibrary.open(Platform.isAndroid ? 'libc.so' : 'libc.so.6');
  }

  @override
  bool get countsSleep => true;

  @override
  int? nowMicros() {
    if (_clockGettime(_linuxClockBoottime, _buffer) != 0) return null;
    final time = _buffer.ref;
    return time.seconds * 1000000 + time.nanoseconds ~/ 1000;
  }
}
