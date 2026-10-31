import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:test/test.dart';

bool _hit(Map<String, List<String>> headers) =>
    isCacheHit(Headers.fromMap(headers));

void main() {
  test('plain responses are not hits', () {
    expect(_hit({}), isFalse);
    expect(
      _hit({
        'date': ['Fri, 30 Oct 2026 20:00:00 GMT'],
      }),
      isFalse,
    );
  });

  group('Age', () {
    test('above 0 is a hit', () {
      expect(
        _hit({
          'age': ['120'],
        }),
        isTrue,
      );
    });

    test('0 alone is not a hit (Varnish sends it on fresh responses)', () {
      expect(
        _hit({
          'age': ['0'],
        }),
        isFalse,
      );
    });

    test('an invalid value counts as a hit', () {
      expect(
        _hit({
          'age': ['abc'],
        }),
        isTrue,
      );
    });
  });

  group('Cache-Status', () {
    test('a hit from dio_cache_plus or any cache is a hit', () {
      expect(
        _hit({
          'cache-status': ['dio_cache_plus; hit; ttl=240'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'cache-status': ['Origin; fwd=miss, CDN; HIT'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'cache-status': ['Origin; fwd=miss', 'CDN; hit'],
        }),
        isTrue,
      );
    });

    test('forwarded responses are not hits', () {
      expect(
        _hit({
          'cache-status': ['dio_cache_plus; fwd=uri-miss; stored'],
        }),
        isFalse,
      );
      expect(
        _hit({
          'cache-status': ['CDN; fwd=stale; fwd-status=200'],
        }),
        isFalse,
      );
    });

    test('a cache named hit is not a hit', () {
      expect(
        _hit({
          'cache-status': ['hit; fwd=miss'],
        }),
        isFalse,
      );
    });
  });

  group('X-Cache', () {
    test('CloudFront', () {
      expect(
        _hit({
          'x-cache': ['Hit from cloudfront'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'x-cache': ['RefreshHit from cloudfront'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'x-cache': ['Miss from cloudfront'],
        }),
        isFalse,
      );
      expect(
        _hit({
          'x-cache': ['Error from cloudfront'],
        }),
        isFalse,
      );
    });

    test('Fastly, Varnish and Squid', () {
      expect(
        _hit({
          'x-cache': ['MISS, HIT'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'x-cache': ['MISS, MISS'],
        }),
        isFalse,
      );
      expect(
        _hit({
          'x-cache': ['TCP_MEM_HIT'],
        }),
        isTrue,
      );
      expect(
        _hit({
          'x-cache': ['TCP_MISS'],
        }),
        isFalse,
      );
    });

    test('words that merely contain "hit" are not hits', () {
      expect(
        _hit({
          'x-cache': ['whitelisted'],
        }),
        isFalse,
      );
    });
  });

  test('Cloudflare', () {
    for (final status in ['HIT', 'stale', 'UPDATING', 'REVALIDATED']) {
      expect(
        _hit({
          'cf-cache-status': [status],
        }),
        isTrue,
        reason: status,
      );
    }
    for (final status in ['MISS', 'EXPIRED', 'BYPASS', 'DYNAMIC']) {
      expect(
        _hit({
          'cf-cache-status': [status],
        }),
        isFalse,
        reason: status,
      );
    }
  });
}
