import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:test/test.dart';

const _date = 'Fri, 30 Oct 2026 20:00:00 GMT';
final _server = DateTime.utc(2026, 10, 30, 20);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(
    this.headers, {
    this.status = 200,
    this.delay,
    this.fail = false,
  });

  final Map<String, List<String>> headers;
  final int status;
  final Duration? delay;
  final bool fail;
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
          ? ServerClockInterceptor(clockOrInterceptor)
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
      final skew = c.now.difference(_server);
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

    test('responses an isFromCache hook flags', () async {
      final c = ServerClock();
      await _dio(
        ServerClockInterceptor(c, isFromCache: (_) => true),
      ).get<dynamic>('/v1/positions');
      expect(c.isSynced, isFalse);
    });
  });

  group('filters', () {
    test('pathPrefixes limits which paths are sampled', () async {
      final c = ServerClock();
      final dio = _dio(ServerClockInterceptor(c, pathPrefixes: ['/v1/orders']));
      await dio.get<dynamic>('/v1/search');
      expect(c.isSynced, isFalse);
      await dio.get<dynamic>('/v1/orders/123');
      expect(c.isSynced, isTrue);
    });

    test('an empty pathPrefixes list samples nothing', () async {
      final c = ServerClock();
      await _dio(
        ServerClockInterceptor(c, pathPrefixes: const []),
      ).get<dynamic>('/v1/orders');
      expect(c.isSynced, isFalse);
    });

    test('include and pathPrefixes must both match', () async {
      final c = ServerClock();
      final dio = _dio(
        ServerClockInterceptor(
          c,
          pathPrefixes: ['/v1/'],
          include: (o) => o.method == 'GET',
        ),
      );
      await dio.post<dynamic>('/v1/orders');
      expect(c.isSynced, isFalse);
      await dio.get<dynamic>('/v2/orders');
      expect(c.isSynced, isFalse);
      await dio.get<dynamic>('/v1/orders');
      expect(c.isSynced, isTrue);
    });

    test('later changes to the prefixes list have no effect', () async {
      final c = ServerClock();
      final prefixes = ['/v1/orders'];
      final dio = _dio(ServerClockInterceptor(c, pathPrefixes: prefixes));
      prefixes.add('/v1/search');
      await dio.get<dynamic>('/v1/search');
      expect(c.isSynced, isFalse);
    });
  });

  group('never breaks requests', () {
    test('when include throws', () async {
      final c = ServerClock();
      final response = await _dio(
        ServerClockInterceptor(c, include: (_) => throw StateError('boom')),
      ).get<dynamic>('/v1/positions');
      expect(response.statusCode, 200);
      expect(c.isSynced, isFalse);
    });

    test('when isFromCache throws', () async {
      final c = ServerClock();
      final response = await _dio(
        ServerClockInterceptor(c, isFromCache: (_) => throw StateError('boom')),
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
          ..interceptors.add(ServerClockInterceptor(c));
    final first = await dio.get<dynamic>('/v1/positions');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    // Resending the same options, as retry interceptors do.
    c.reset();
    await dio.fetch<dynamic>(first.requestOptions);
    expect(adapter.calls, 2);
    expect(c.isSynced, isTrue);
  });
}
