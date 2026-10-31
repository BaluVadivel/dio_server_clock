import 'monotonic.dart';

/// No boot clock without `dart:ffi` (web).
MonotonicSource? createBootClock() => null;
