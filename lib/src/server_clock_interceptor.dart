import 'package:dio/dio.dart';

import 'cache_detection.dart';
import 'server_clock.dart';
import 'url_rule.dart';

/// Feeds a [ServerClock] from the `Date` header of Dio responses.
///
/// ```dart
/// dio.interceptors.add(ServerClockInterceptor()); // add it last
/// final now = ServerClock.instance.now;
/// ```
///
/// For each response it measures the round trip, skips cached copies, and
/// passes the `Date` header to [ServerClock.addHttpDate]. Error responses
/// (401, 500) are sampled too, because they come from the live server.
///
/// Add it last, after interceptors that do slow work in `onRequest` (token
/// refresh, reading secure storage) and after any caching interceptor. The
/// round trip is measured from this interceptor's `onRequest`, so earlier
/// delays don't count, and cache hits resolved by an earlier interceptor
/// never reach it.
///
/// It never throws while handling requests and never changes requests or
/// responses. If a callback you pass throws, the request goes through and
/// only the sample is skipped.
class ServerClockInterceptor extends Interceptor {
  /// Creates an interceptor that feeds [serverClock], or
  /// [ServerClock.instance] when it is null.
  ///
  /// Pass your own [ServerClock] for a backend whose clock is independent of
  /// your main servers (for example a third-party service), for custom
  /// settings, or in tests. Several Dio instances for the same backend
  /// should feed the same clock.
  ///
  /// With no other arguments, every response is sampled unless the default
  /// cache check skips it. The arguments narrow that down.
  ///
  /// **Which requests are sampled** (checked before the request is sent). A
  /// request is sampled only if all three pass, so each one can only remove
  /// requests, never add them back:
  ///
  /// - [allow]: the request URL must match at least one entry. Null (the
  ///   default) allows every URL; an empty list allows none.
  /// - [deny]: the request URL must match no entry. Deny always wins: a broad
  ///   [allow] entry never overrides a narrower [deny] entry, whatever the
  ///   order or how specific the entries are.
  /// - [include]: your own test on the whole [RequestOptions] (method,
  ///   headers, `extra`, build flavour), for rules a URL list can't express.
  ///   Return true to sample, false to skip. Null samples every request.
  ///
  /// An [allow] or [deny] entry is either:
  ///
  /// - a path, `/api/v1/user`: matches that path and below on any host;
  /// - a URL, `https://api.example.com` or `https://api.example.com/v1/user`:
  ///   matches the same scheme, host and port, and that path and below.
  ///
  /// Paths match at `/` boundaries, so `/api/user` matches `/api/user/42`
  /// but not `/api/users`. Hosts ignore case, paths don't; a default port
  /// equals no port; a trailing `/` and the request's query are ignored.
  /// Entries are matched against the resolved URL, so `baseUrl` + path and
  /// full URLs both work. An empty entry, a URL without a scheme or host, or
  /// an entry with a query or fragment throws an [ArgumentError] here.
  ///
  /// **Which responses are cached copies** (checked after the response
  /// arrives): [cacheVerdict] runs first and returns a [CacheVerdict]:
  /// [CacheVerdict.cached] skips the response, [CacheVerdict.fresh] samples
  /// it, and [CacheVerdict.useDefault] leaves it to the default check, which
  /// skips `304` responses and those [isCacheHit] detects. Null always uses
  /// the default check. A throwing [cacheVerdict] skips the response.
  ///
  /// ```dart
  /// ServerClockInterceptor(
  ///   allow: ['https://api.example.com'],
  ///   deny: ['/v1/public'],
  ///   include: (options) => options.extra['skipClock'] != true,
  ///   cacheVerdict: (response) => response.extra['fromLocalCache'] == true
  ///       ? CacheVerdict.cached
  ///       : CacheVerdict.useDefault,
  /// );
  /// ```
  ServerClockInterceptor({
    ServerClock? serverClock,
    List<String>? allow,
    List<String>? deny,
    bool Function(RequestOptions options)? include,
    CacheVerdict Function(Response<dynamic> response)? cacheVerdict,
  }) : serverClock = serverClock ?? ServerClock.instance,
       _allow = allow?.map(UrlRule.parse).toList(growable: false),
       _deny = deny?.map(UrlRule.parse).toList(growable: false),
       _include = include,
       _cacheVerdict = cacheVerdict;

  /// The clock this interceptor feeds: the one passed in, or
  /// [ServerClock.instance].
  final ServerClock serverClock;

  final List<UrlRule>? _allow;
  final List<UrlRule>? _deny;
  final bool Function(RequestOptions options)? _include;

  // Runs before the default check; useDefault falls through to it, so an
  // app can't drop the default check by forgetting to call it.
  final CacheVerdict Function(Response<dynamic> response)? _cacheVerdict;

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
    final allow = _allow;
    final deny = _deny;
    if (allow != null || deny != null) {
      final uri = options.uri;
      if (allow != null && !allow.any((r) => r.matches(uri))) return false;
      if (deny != null && deny.any((r) => r.matches(uri))) return false;
    }
    return _include?.call(options) ?? true;
  }

  /// Whether [response] is a cached copy. A throwing [_cacheVerdict] counts
  /// as cached: skipping a sample is safer than anchoring to an old `Date`.
  bool _isCached(Response<dynamic> response) {
    final verdict = _cacheVerdict;
    if (verdict != null) {
      final CacheVerdict result;
      try {
        result = verdict(response);
      } catch (_) {
        return true;
      }
      switch (result) {
        case CacheVerdict.cached:
          return true;
        case CacheVerdict.fresh:
          return false;
        case CacheVerdict.useDefault:
          break;
      }
    }
    return response.statusCode == 304 || isCacheHit(response.headers);
  }

  void _sample(RequestOptions options, Response<dynamic>? response) {
    try {
      final start = options.extra.remove(_startKey);
      if (start is! int || response == null) return;
      final end = monotonicSourceOf(serverClock).nowMicros();
      if (end == null || end < start) return;
      final roundTrip = Duration(microseconds: end - start);

      if (_isCached(response)) return;

      final date = _singleValue(response.headers['date']);
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
