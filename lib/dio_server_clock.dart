/// Tamper-resistant server time for Dio apps.
///
/// Reads the HTTP `Date` header from responses you already make, and keeps
/// the time on a monotonic clock that device time and timezone changes can't
/// affect. The time is valid or null, never the device clock.
///
/// ```dart
/// dio.interceptors.add(ServerClockInterceptor());
///
/// final now = ServerClock.instance.now; // null until the first response
/// ```
///
/// - [ServerClock]: the clock; read [ServerClock.now] or [ServerClock.nowIn].
/// - [ServerClockInterceptor]: feeds it from Dio responses, with filters for
///   which requests to sample and which responses are cached copies.
/// - [CacheVerdict] and [isCacheHit]: cache detection.
/// - [ClockSample]: details of each accepted sample.
library;

export 'src/cache_detection.dart' show CacheVerdict, isCacheHit;
export 'src/clock_sample.dart';
export 'src/server_clock.dart' show ServerClock;
export 'src/server_clock_interceptor.dart';
