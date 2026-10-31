import 'package:dio/dio.dart';

const _cloudflareHits = {'HIT', 'STALE', 'UPDATING', 'REVALIDATED'};

/// True when response headers show the response came from a cache, so its
/// `Date` header may be old.
///
/// Detects:
/// - `Age` above 0 (RFC 9111). `Age: 0` alone is not a hit, because some
///   proxies (for example Varnish) send it on fresh responses.
/// - A `Cache-Status` member with the `hit` parameter (RFC 9211), from any
///   cache, including local caches such as `dio_cache_plus`.
/// - `X-Cache` hits from AWS CloudFront, Fastly, Varnish and Squid.
/// - `CF-Cache-Status` hits from Cloudflare.
bool isCacheHit(Headers headers) {
  final age = headers['age'];
  if (age != null && age.any(_isPositiveOrInvalidAge)) return true;

  final cacheStatus = headers['cache-status'];
  if (cacheStatus != null && cacheStatus.any(_hasCacheStatusHit)) return true;

  final xCache = headers['x-cache'];
  if (xCache != null && xCache.any(_isXCacheHit)) return true;

  final cf = headers['cf-cache-status'];
  return cf != null &&
      cf.any((v) => _cloudflareHits.contains(v.trim().toUpperCase()));
}

// An unparsable Age counts as a hit: rejecting one sample is cheaper than
// anchoring to an old Date.
bool _isPositiveOrInvalidAge(String value) {
  final seconds = int.tryParse(value.trim());
  return seconds == null || seconds > 0;
}

// `Cache-Status: Origin; fwd=miss, CDN; hit; ttl=30` has two members; any
// member with a bare `hit` parameter means a cache answered.
bool _hasCacheStatusHit(String value) => value
    .split(',')
    .any(
      (member) => member
          .split(';')
          .skip(1)
          .any((param) => param.trim().toLowerCase() == 'hit'),
    );

// CloudFront: `Hit from cloudfront`, `RefreshHit from cloudfront`.
// Fastly: `HIT`, `HIT, MISS` (shield and edge). Squid: `TCP_HIT`, `TCP_MEM_HIT`.
bool _isXCacheHit(String value) => value.split(',').any((part) {
  final token = part.trim().toLowerCase();
  return token.startsWith('hit') ||
      token.startsWith('refreshhit') ||
      token.contains('_hit');
});
