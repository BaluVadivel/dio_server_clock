import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:dio_server_clock/src/monotonic.dart';
import 'package:test/test.dart';

import 'fake_source.dart';

const _date = 'Fri, 30 Oct 2026 20:00:00 GMT';
final _server = DateTime.utc(2026, 10, 30, 20);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(
    this.headers, {
    this.status = 200,
    this.delay,
    this.fail = false,
    this.onFetch,
  });

  final Map<String, List<String>> headers;
  final int status;
  final Duration? delay;
  final bool fail;
  final void Function()? onFetch;
  int calls = 0;

  // `Future<dynamic>?` matches both Dio 4 (`Future?`) and Dio 5
  // (`Future<void>?`).
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    calls++;
    onFetch?.call();
    if (delay != null) await Future<void>.delayed(delay!);
    if (fail) throw StateError('connection failed');
    return ResponseBody.fromString('{}', status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

/// Answers from a fake local cache, like `dio_cache_plus` does.
class _CacheInterceptor extends Interceptor {
  _CacheInterceptor({required this.callFollowing});

  final bool callFollowing;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        headers: Headers.fromMap({
          'date': ['Fri, 30 Oct 2026 10:00:00 GMT'],
          'cache-status': ['dio_cache_plus; hit; ttl=240'],
          'age': ['36000'],
        }),
      ),
      callFollowing,
    );
  }
}

Dio _dio(
  Object clockOrInterceptor, {
  Map<String, List<String>> headers = const {
    'date': [_date],
  },
  int status = 200,
  Duration? delay,
  bool fail = false,
  List<Interceptor> before = const [],
}) {
  final interceptor =
      clockOrInterceptor is ServerClock
          ? ServerClockInterceptor(serverClock: clockOrInterceptor)
          : clockOrInterceptor as ServerClockInterceptor;
  return Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = _FakeAdapter(
      headers,
      status: status,
      delay: delay,
      fail: fail,
    )
    ..interceptors.addAll([...before, interceptor]);
}

void main() {
  group('samples', () {
    test('a fresh response', () async {
      final c = ServerClock();
      await _dio(c).get<dynamic>('/v1/positions');
      expect(c.isSynced, isTrue);
      final skew = c.now!.difference(_server);
      // Half a second for the Date window plus half a tiny round trip.
      expect(skew, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
      expect(skew, lessThan(const Duration(seconds: 2)));
    });

    test('error responses from the live server', () async {
      for (final status in [401, 404, 500]) {
        final c = ServerClock();
        await expectLater(
          _dio(c, status: status).get<dynamic>('/v1/positions'),
          throwsA(isA<Exception>()),
        );
        expect(c.isSynced, isTrue, reason: '$status');
      }
    });

    test('a network response marked by dio_cache_plus as forwarded', () async {
      final c = ServerClock();
      await _dio(
        c,
        headers: {
          'date': [_date],
          'cache-status': ['dio_cache_plus; fwd=uri-miss; stored'],
        },
      ).get<dynamic>('/v1/positions');
      expect(c.isSynced, isTrue);
    });

    test('a Date header repeated with the same value', () async {
      final c = ServerClock();
      await _dio(
        c,
        headers: {
          'date': [_date, _date],
        },
      ).get<dynamic>('/v1/positions');
      expect(c.isSynced, isTrue);
    });
  });

  group('skips', () {
    Future<bool> synced(
      Map<String, List<String>> headers, {
      int status = 200,
    }) async {
      final c = ServerClock();
      try {
        await _dio(c, headers: headers, status: status).get<dynamic>('/v1/x');
      } on Exception catch (_) {}
      return c.isSynced;
    }

    test('CDN and local cache hits', () async {
      expect(
        await synced({
          'date': [_date],
          'x-cache': ['Hit from cloudfront'],
        }),
        isFalse,
      );
      expect(
        await synced({
          'date': [_date],
          'age': ['120'],
        }),
        isFalse,
      );
      expect(
        await synced({
          'date': [_date],
          'cache-status': ['dio_cache_plus; hit; ttl=10'],
        }),
        isFalse,
      );
    });

    test('304 Not Modified', () async {
      expect(
        await synced({
          'date': [_date],
        }, status: 304),
        isFalse,
      );
    });

    test('missing, empty, invalid or conflicting Date', () async {
      expect(await synced({}), isFalse);
      expect(
        await synced({
          'date': [''],
        }),
        isFalse,
      );
      expect(
        await synced({
          'date': ['yesterday'],
        }),
        isFalse,
      );
      expect(
        await synced({
          'date': [_date, 'Fri, 30 Oct 2026 21:00:00 GMT'],
        }),
        isFalse,
      );
    });

    test('network failures with no response', () async {
      final c = ServerClock();
      await expectLater(
        _dio(c, fail: true).get<dynamic>('/v1/positions'),
        throwsA(isA<Exception>()),
      );
      expect(c.isSynced, isFalse);
    });

    test('responses slower than the round-trip limit', () async {
      final c = ServerClock(
        maxRoundTripBeforeSync: const Duration(milliseconds: 50),
      );
      await _dio(
        c,
        delay: const Duration(milliseconds: 150),
      ).get<dynamic>('/v1/positions');
      expect(c.isSynced, isFalse);
    });
  });

  group('cacheVerdict', () {
    Future<bool> synced(
      CacheVerdict Function(Response<dynamic>) verdict, {
      Map<String, List<String>> headers = const {
        'date': [_date],
      },
      int status = 200,
    }) async {
      final c = ServerClock();
      try {
        await _dio(
          ServerClockInterceptor(serverClock: c, cacheVerdict: verdict),
          headers: headers,
          status: status,
        ).get<dynamic>('/v1/positions');
      } on Exception catch (_) {}
      return c.isSynced;
    }

    const cdnHit = {
      'date': [_date],
      'x-cache': ['Hit from cloudfront'],
    };

    test('cached skips a response the default check would sample', () async {
      expect(await synced((_) => CacheVerdict.cached), isFalse);
    });

    test('cached can come from an app flag in extra', () async {
      final c = ServerClock();
      await _dio(
        ServerClockInterceptor(
          serverClock: c,
          cacheVerdict:
              (r) =>
                  r.requestOptions.extra['offline'] == true
                      ? CacheVerdict.cached
                      : CacheVerdict.useDefault,
        ),
      ).get<dynamic>(
        '/v1/positions',
        options: Options(extra: {'offline': true}),
      );
      expect(c.isSynced, isFalse);
    });

    test('fresh overrules a header cache hit', () async {
      expect(await synced((_) => CacheVerdict.fresh, headers: cdnHit), isTrue);
    });

    test('fresh overrules the 304 check', () async {
      expect(await synced((_) => CacheVerdict.fresh, status: 304), isTrue);
    });

    test('useDefault keeps the default check', () async {
      expect(
        await synced((_) => CacheVerdict.useDefault, headers: cdnHit),
        isFalse,
      );
      expect(
        await synced((_) => CacheVerdict.useDefault, status: 304),
        isFalse,
      );
      expect(await synced((_) => CacheVerdict.useDefault), isTrue);
    });

    test('decides per response', () async {
      final c = ServerClock();
      final dio = _dio(
        ServerClockInterceptor(
          serverClock: c,
          cacheVerdict:
              (r) =>
                  r.requestOptions.path.startsWith('/v1/user')
                      ? CacheVerdict.fresh
                      : CacheVerdict.useDefault,
        ),
        headers: cdnHit,
      );
      await dio.get<dynamic>('/v1/search');
      expect(c.isSynced, isFalse);
      await dio.get<dynamic>('/v1/user/me');
      expect(c.isSynced, isTrue);
    });

    test('a throwing callback skips the sample', () async {
      expect(await synced((_) => throw StateError('boom')), isFalse);
    });
  });

  group('allow and deny', () {
    Future<List<String>> sampled(
      ServerClockInterceptor Function(ServerClock) build,
      List<String> urls,
    ) async {
      final result = <String>[];
      for (final url in urls) {
        final c = ServerClock();
        await _dio(build(c)).get<dynamic>(url);
        if (c.isSynced) result.add(url);
      }
      return result;
    }

    test('null lists sample every URL', () async {
      expect(
        await sampled((c) => ServerClockInterceptor(serverClock: c), [
          '/v1/x',
          'https://other.example.org/y',
        ]),
        hasLength(2),
      );
    });

    test('allow with a base URL, a full URL and a path', () async {
      final result = await sampled(
        (c) => ServerClockInterceptor(
          serverClock: c,
          allow: [
            'https://api.example.com/v1/user',
            'https://auth.example.org',
            '/v2/orders',
          ],
        ),
        [
          '/v1/user', // baseUrl + path
          '/v1/user/42',
          '/v1/users', // not at a / boundary
          '/v1/search',
          'https://auth.example.org/login',
          'http://auth.example.org/login', // other scheme
          'https://auth.example.org:8443/login', // other port
          'https://cdn.example.net/v2/orders/1', // path entry, any host
          '/v2/orders?page=2',
        ],
      );
      expect(result, [
        '/v1/user',
        '/v1/user/42',
        'https://auth.example.org/login',
        'https://cdn.example.net/v2/orders/1',
        '/v2/orders?page=2',
      ]);
    });

    test('an empty allow list samples nothing', () async {
      expect(
        await sampled(
          (c) => ServerClockInterceptor(serverClock: c, allow: const []),
          ['/v1/x'],
        ),
        isEmpty,
      );
    });

    test('deny skips matching URLs and wins over allow', () async {
      final result = await sampled(
        (c) => ServerClockInterceptor(
          serverClock: c,
          allow: ['https://api.example.com'],
          deny: ['/v1/public', 'https://api.example.com/v1/config'],
        ),
        ['/v1/user', '/v1/public/feed', '/v1/config', '/v1/configs'],
      );
      expect(result, ['/v1/user', '/v1/configs']);
    });

    test('a narrow deny path beats a broad allow URL', () async {
      final result = await sampled(
        (c) => ServerClockInterceptor(
          serverClock: c,
          // Order doesn't matter either: deny is listed first here.
          deny: ['/api/v1/public', 'https://cdn.example.com'],
          allow: ['https://api.example.com', 'https://cdn.example.com'],
        ),
        [
          '/api/v1/user/me',
          '/api/v1/public',
          '/api/v1/public/feed',
          '/api/v1/publicity', // not at a / boundary
          'https://cdn.example.com/x', // in both lists
        ],
      );
      expect(result, ['/api/v1/user/me', '/api/v1/publicity']);
    });

    test('allow, deny and include must all pass', () async {
      final c = ServerClock();
      final dio = _dio(
        ServerClockInterceptor(
          serverClock: c,
          allow: ['/v1'],
          deny: ['/v1/search'],
          include: (o) => o.method == 'GET',
        ),
      );
      await dio.post<dynamic>('/v1/orders');
      await dio.get<dynamic>('/v1/search');
      await dio.get<dynamic>('/v2/orders');
      expect(c.isSynced, isFalse);
      await dio.get<dynamic>('/v1/orders');
      expect(c.isSynced, isTrue);
    });

    test('later changes to the lists have no effect', () async {
      final c = ServerClock();
      final allow = ['/v1/orders'];
      final dio = _dio(ServerClockInterceptor(serverClock: c, allow: allow));
      allow.add('/v1/search');
      await dio.get<dynamic>('/v1/search');
      expect(c.isSynced, isFalse);
    });

    test('invalid entries throw when the interceptor is created', () {
      final c = ServerClock();
      for (final entry in [
        '',
        '  ',
        'api.example.com',
        '//api.example.com',
        'https://',
        'https://api.example.com/x?a=1',
        '/x#top',
      ]) {
        expect(
          () => ServerClockInterceptor(serverClock: c, allow: [entry]),
          throwsArgumentError,
          reason: entry,
        );
        expect(
          () => ServerClockInterceptor(serverClock: c, deny: [entry]),
          throwsArgumentError,
          reason: entry,
        );
      }
    });
  });

  group('never breaks requests', () {
    test('when include throws', () async {
      final c = ServerClock();
      final response = await _dio(
        ServerClockInterceptor(
          serverClock: c,
          include: (_) => throw StateError('boom'),
        ),
      ).get<dynamic>('/v1/positions');
      expect(response.statusCode, 200);
      expect(c.isSynced, isFalse);
    });

    test('when cacheVerdict throws', () async {
      final c = ServerClock();
      final response = await _dio(
        ServerClockInterceptor(
          serverClock: c,
          cacheVerdict: (_) => throw StateError('boom'),
        ),
      ).get<dynamic>('/v1/positions');
      expect(response.statusCode, 200);
      expect(c.isSynced, isFalse);
    });

    test('responses and their headers are passed on unchanged', () async {
      final c = ServerClock();
      final response = await _dio(c).get<dynamic>('/v1/positions');
      expect(response.headers.map.keys, ['date']);
      expect(response.requestOptions.extra, isEmpty);
    });
  });

  group('with a local cache interceptor before it', () {
    test('cache hits resolved early never reach it', () async {
      final c = ServerClock();
      final response = await _dio(
        c,
        before: [_CacheInterceptor(callFollowing: false)],
      ).get<dynamic>('/v1/positions');
      expect(response.statusCode, 200);
      expect(c.isSynced, isFalse);
    });

    test('cache hits passed on to it are skipped', () async {
      final c = ServerClock();
      await _dio(
        c,
        before: [_CacheInterceptor(callFollowing: true)],
      ).get<dynamic>('/v1/positions');
      expect(c.isSynced, isFalse);
    });
  });

  test('a retried request restarts its stopwatch', () async {
    final c = ServerClock(maxRoundTripBeforeSync: const Duration(seconds: 1));
    final adapter = _FakeAdapter(const {
      'date': [_date],
    });
    final dio =
        Dio(BaseOptions(baseUrl: 'https://api.example.com'))
          ..httpClientAdapter = adapter
          ..interceptors.add(ServerClockInterceptor(serverClock: c));
    final first = await dio.get<dynamic>('/v1/positions');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // Resending the same options, as retry interceptors do.
    c.reset();
    await dio.fetch<dynamic>(first.requestOptions);
    expect(adapter.calls, 2);
    expect(c.isSynced, isTrue);
  });

  group('round trip on the clock\'s monotonic source', () {
    late FakeSource source;
    setUp(() => monotonicSourceOverride = source = FakeSource());
    tearDown(() => monotonicSourceOverride = null);

    Future<ServerClock> request(Duration networkTime) async {
      final c = ServerClock();
      final dio =
          Dio(BaseOptions(baseUrl: 'https://api.example.com'))
            ..httpClientAdapter = _FakeAdapter(const {
              'date': [_date],
            }, onFetch: () => source.advance(networkTime))
            ..interceptors.add(ServerClockInterceptor(serverClock: c));
      await dio.get<dynamic>('/v1/positions');
      return c;
    }

    test('is measured and corrected for', () async {
      final c = await request(const Duration(seconds: 3));
      // Half the round trip plus half the Date window.
      expect(c.uncertainty, const Duration(seconds: 2));
      expect(c.now, _server.add(const Duration(seconds: 2)));
    });

    test('over the limit is rejected', () async {
      final c = await request(const Duration(seconds: 11));
      expect(c.now, isNull);
    });

    test('a monotonic clock that fails mid-request is skipped', () async {
      final c = ServerClock();
      final dio =
          Dio(BaseOptions(baseUrl: 'https://api.example.com'))
            ..httpClientAdapter = _FakeAdapter(const {
              'date': [_date],
            }, onFetch: () => source.micros = null)
            ..interceptors.add(ServerClockInterceptor(serverClock: c));
      final response = await dio.get<dynamic>('/v1/positions');
      expect(response.statusCode, 200);
      expect(c.now, isNull);
    });
  });
}
