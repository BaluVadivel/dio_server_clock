import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:test/test.dart';

// Its own file: each test file runs in a fresh isolate, so the shared clock
// starts here with no time and the real monotonic source.

const _date = 'Fri, 30 Oct 2026 20:00:00 GMT';

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{}',
    200,
    headers: {
      'date': [_date],
    },
  );

  @override
  void close({bool force = false}) {}
}

Dio _dio(ServerClockInterceptor interceptor) =>
    Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = _Adapter()
      ..interceptors.add(interceptor);

void main() {
  setUp(ServerClock.instance.reset);

  test('is one clock with the default settings', () {
    expect(identical(ServerClock.instance, ServerClock.instance), isTrue);
    final shared = ServerClock.instance;
    final created = ServerClock();
    expect(shared.maxRoundTrip, created.maxRoundTrip);
    expect(shared.maxRoundTripBeforeSync, created.maxRoundTripBeforeSync);
    expect(shared.tolerance, created.tolerance);
    expect(shared.now, isNull);
  });

  test('an interceptor without a clock feeds the shared one', () async {
    final interceptor = ServerClockInterceptor();
    expect(identical(interceptor.serverClock, ServerClock.instance), isTrue);
    await _dio(interceptor).get<dynamic>('/v1/x');
    expect(ServerClock.instance.isSynced, isTrue);
  });

  test('several Dio instances feed the same shared clock', () async {
    final first = ServerClockInterceptor();
    final second = ServerClockInterceptor();
    expect(identical(first.serverClock, second.serverClock), isTrue);
    _dio(first); // never used
    await _dio(second).get<dynamic>('/v1/y');
    expect(first.serverClock.isSynced, isTrue);
  });

  test(
    'an interceptor with its own clock leaves the shared one alone',
    () async {
      final own = ServerClock();
      await _dio(
        ServerClockInterceptor(serverClock: own),
      ).get<dynamic>('/v1/x');
      expect(own.isSynced, isTrue);
      expect(ServerClock.instance.isSynced, isFalse);
    },
  );

  test('dispose does nothing on the shared clock', () async {
    final events = <bool>[];
    final sub = ServerClock.instance.onSyncChanged.listen(events.add);
    await ServerClock.instance.dispose();
    ServerClock.instance.addHttpDate(_date, Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, [true]);
    await sub.cancel();
  });

  test('dispose still closes the streams of a created clock', () async {
    final own = ServerClock();
    final done = Completer<void>();
    own.onSyncChanged.listen(null, onDone: done.complete);
    await own.dispose();
    await done.future.timeout(const Duration(seconds: 1));
  });
}
