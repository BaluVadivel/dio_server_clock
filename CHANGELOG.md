# Changelog

All notable changes to dio_server_clock will be documented in this file.

## [Unreleased]

## [0.1.0] - 2026-Oct-31

### Added
- `ServerClock`: server time anchored to a monotonic stopwatch, with `now`, `nowIn`, `isSynced`, `deviceSkew`, `uncertainty`, `onAnchor`, `invalidate` and `reset`
- `ServerClockInterceptor`: samples the HTTP `Date` header from Dio responses, including error responses, with `pathPrefixes`, `include` and `isFromCache` filters
- `isCacheHit`: detects cached responses from `Age`, `Cache-Status` (RFC 9211), `X-Cache` and `CF-Cache-Status` headers
- Supports Dio 4 and 5; pure Dart, no Flutter dependency
