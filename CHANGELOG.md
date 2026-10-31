# Changelog

All notable changes to dio_server_clock will be documented in this file.

## [Unreleased]

Breaking release: the clock now gives a valid time or no time.

### Breaking
- `now` and `nowIn` return `DateTime?`: null before the first accepted response, after `reset()`, and after `invalidate()` where sleep isn't counted. They no longer fall back to the device clock
- `isSynced`, `deviceSkew` and `uncertainty` follow `now`: false or null whenever `now` is null
- `maxAnchorAge` is removed; the newest acceptable response now wins
- `invalidate()` clears the time where the clock may pause in deep sleep (web, Windows); on Android, iOS, macOS and Linux it keeps the time
- `onAnchor` fires for every accepted response
- `ServerClockInterceptor`: `pathPrefixes` is replaced by `allow`, whose path entries match at `/` boundaries (`/api/user` no longer matches `/api/users`)
- `ServerClockInterceptor`: `isFromCache` is replaced by `cacheVerdict`
- `ServerClockInterceptor`: the clock is now the optional named `serverClock:` argument, defaulting to `ServerClock.instance`

### Added
- The time runs on the platform boot clock, which keeps counting through deep sleep: `CLOCK_BOOTTIME` on Android and Linux, `CLOCK_MONOTONIC` on iOS and macOS, through `dart:ffi`. Web, Windows and any failure fall back to `Stopwatch`. `countsSleep` reports which is in use
- `tolerance` (default 5 s): a response more than this ahead replaces a stale time at once; one more than this behind (a cached copy) is ignored, unless three in a row agree, meaning the server's clock moved back
- `onSyncChanged`: a `Stream<bool>` that fires when the time is gained or lost
- `ServerClock.instance`: a shared clock that `ServerClockInterceptor()` feeds by default, so most apps don't create or pass a clock. `dispose()` does nothing on it
- `allow` and `deny` on `ServerClockInterceptor`: lists of paths (`/api/v1/user`, any host), base URLs (`https://api.example.com`) or URLs with a path. Deny wins; invalid entries throw `ArgumentError` when the interceptor is created
- `cacheVerdict` on `ServerClockInterceptor`, returning a `CacheVerdict`: `cached` skips a response, `fresh` samples it despite the default cache check, `useDefault` leaves it to the default check
- The example is now a Flutter test app for Android and iOS, with a deep-sleep check

### Migration from 0.1.0
- Handle null wherever you read the time: `final now = ServerClock.instance.now; if (now == null) { /* unknown: show "syncing…" */ }`. Don't replace null with `DateTime.now()` in decisions
- Remove `maxAnchorAge:` from `ServerClock(...)`
- `pathPrefixes: ['/api/v1/']` becomes `allow: ['/api/v1']`. Note the `/` boundary: a prefix that relied on partial matches (`/api/user` for `/api/users`) needs each path listed
- `ServerClockInterceptor(myClock)` becomes `ServerClockInterceptor(serverClock: myClock)`, or `ServerClockInterceptor()` with `ServerClock.instance` in place of your clock
- `isFromCache: (r) => cond` becomes `cacheVerdict: (r) => cond ? CacheVerdict.cached : CacheVerdict.useDefault`
- Keep calling `invalidate()` on app resume

## [0.1.0] - 2026-Oct-31

### Added
- `ServerClock`: server time anchored to a monotonic stopwatch, with `now`, `nowIn`, `isSynced`, `deviceSkew`, `uncertainty`, `onAnchor`, `invalidate` and `reset`
- `ServerClockInterceptor`: samples the HTTP `Date` header from Dio responses, including error responses, with `pathPrefixes`, `include` and `isFromCache` filters
- `isCacheHit`: detects cached responses from `Age`, `Cache-Status` (RFC 9211), `X-Cache` and `CF-Cache-Status` headers
- Supports Dio 4 and 5; pure Dart, no Flutter dependency
