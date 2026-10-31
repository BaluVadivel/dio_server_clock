import 'package:dio/dio.dart';

import 'cache_detection.dart';
import 'server_clock.dart';

/// Feeds a [ServerClock] from the `Date` header of Dio responses.
///
/// Add it last, after interceptors that do slow work in `onRequest` (token
/// refresh, reading secure storage) and after any caching interceptor. The
/// round trip is measured from this interceptor's `onRequest`, so earlier
/// delays don't count, and cache hits resolved by an earlier interceptor
/// never reach it.
///
/// It never throws and never changes requests or responses.
class ServerClockInterceptor extends Interceptor {
  /// Samples every request whose path starts with one of [pathPrefixes] (all
  /// paths when null) and for which [include] returns true (all requests when
  /// null).
  ServerClockInterceptor(
    this.serverClock, {
    List<String>? pathPrefixes,
    bool Function(RequestOptions options)? include,
    this.isFromCache,
  }) : _pathPrefixes = pathPrefixes == null ? null : List.of(pathPrefixes),
       _include = include;

  /// The clock this interceptor feeds.
  final ServerClock serverClock;

  final List<String>? _pathPrefixes;
  final bool Function(RequestOptions options)? _include;

  /// Extra cache check for setups whose cache marks responses in a way
  /// [isCacheHit] can't see (for example a flag in `response.extra`).
  /// Header-based cache hits are always detected.
  final bool Function(Response<dynamic> response)? isFromCache;

  static const _startKey = 'dio_server_clock.start';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      // Runs on every attempt, so a retried request is timed from its resend.
      // The start time, on the clock's own monotonic source.
      final start =
          _shouldSample(options)
              ? monotonicSourceOf(serverClock).nowMicros()
              : null;
      if (start != null) {
        options.extra[_startKey] = start;
      } else {
        options.extra.remove(_startKey);
      }
    } catch (_) {
      // A throwing filter must not break the request.
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _sample(response.requestOptions, response);
    handler.next(response);
  }

  // The error type is left to inference: DioError in Dio 4, DioException in
  // Dio 5.
  @override
  void onError(err, ErrorInterceptorHandler handler) {
    // A 401 or 500 from the live server still carries a fresh Date header.
    _sample(err.requestOptions, err.response);
    handler.next(err);
  }

  bool _shouldSample(RequestOptions options) {
    final prefixes = _pathPrefixes;
    if (prefixes != null) {
      final path = options.uri.path;
      if (!prefixes.any(path.startsWith)) return false;
    }
    return _include?.call(options) ?? true;
  }

  void _sample(RequestOptions options, Response<dynamic>? response) {
    try {
      final start = options.extra.remove(_startKey);
      if (start is! int || response == null) return;
      final end = monotonicSourceOf(serverClock).nowMicros();
      if (end == null || end < start) return;
      final roundTrip = Duration(microseconds: end - start);

      if (response.statusCode == 304) return;
      final headers = response.headers;
      if (isCacheHit(headers)) return;
      if (isFromCache?.call(response) ?? false) return;

      final date = _singleValue(headers['date']);
      if (date == null) return;
      serverClock.addHttpDate(date, roundTrip);
    } catch (_) {
      // Sampling is best effort; never break the response.
    }
  }

  /// The header's value, or null when it is missing or repeated with
  /// different values.
  static String? _singleValue(List<String>? values) {
    if (values == null || values.isEmpty) return null;
    final first = values.first.trim();
    if (first.isEmpty) return null;
    for (final value in values.skip(1)) {
      if (value.trim() != first) return null;
    }
    return first;
  }
}
