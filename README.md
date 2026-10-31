# dio_server_clock

[![pub package](https://img.shields.io/pub/v/dio_server_clock.svg)](https://pub.dev/packages/dio_server_clock)
[![pub points](https://img.shields.io/pub/points/dio_server_clock)](https://pub.dev/packages/dio_server_clock/score)
[![likes](https://img.shields.io/pub/likes/dio_server_clock)](https://pub.dev/packages/dio_server_clock/score)
[![downloads](https://img.shields.io/pub/dm/dio_server_clock)](https://pub.dev/packages/dio_server_clock/score)
[![CI](https://github.com/BaluVadivel/dio_server_clock/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/BaluVadivel/dio_server_clock/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/github/license/BaluVadivel/dio_server_clock)](https://github.com/BaluVadivel/dio_server_clock/blob/main/LICENSE)

Tamper-resistant server time for [Dio](https://pub.dev/packages/dio) apps. Reads the HTTP `Date` header from responses you already make and anchors it to a monotonic clock, so device time and timezone changes have no effect.

- **Valid time or no time:** `now` is the server time, or null when it can't be trusted. Never the device clock
- No extra requests and no backend changes
- Keeps counting through deep sleep on Android and iOS
- Corrects for network delay and skips cached responses
- Pure Dart: works in Flutter, CLI and server apps, on Dio 4 and 5

## Why

`DateTime.now()` trusts a clock and a timezone the user controls. If the phone's time is off, changed by hand, or set to another timezone, any time-based decision in the app (market hours, offer windows, cut-off times) is wrong.

## How it works

Every HTTP response carries a `Date` header. The HTTP standard (RFC 9110) requires servers with a clock to send it, and web servers and CDNs (Nginx, Apache, CloudFront, Cloudflare) add it on their own, including on 401 and 500 responses. It is always UTC, with one-second resolution.

```mermaid
flowchart LR
    A["Response arrives<br/>Date header + round trip"] --> B["Filter the sample<br/>allowed path, not cached, fast enough"]
    B --> C["Set the anchor<br/>server time + round trip / 2<br/>monotonic reading saved"]
    C --> D["Read the time<br/>anchor + monotonic time since"]
```

The monotonic clock only moves forward and ignores device time and timezone changes, so the time stays correct between samples. Each accepted response replaces the anchor, so the time is as fresh as your latest API call.

## Quick start

```yaml
dependencies:
  dio_server_clock: ^0.2.0
```

```dart
import 'package:dio_server_clock/dio_server_clock.dart';

final serverClock = ServerClock(); // one per backend, app-wide

dio.interceptors.add(ServerClockInterceptor(serverClock)); // add it last

final now = serverClock.now; // DateTime? in UTC; null = no valid time yet
if (now == null) {
  // Show "syncing…" or a neutral state; don't guess.
}
```

## Valid time or no time

`now` returns the server time to within about a second, or **null**. It never falls back to the device clock.

| Situation | `now` |
| --- | --- |
| Before the first accepted response (cold start, offline at launch) | null |
| After `reset()` | null |
| After `invalidate()` where the clock may pause in deep sleep (web, Windows) | null until the next response |
| Otherwise, including after deep sleep on Android and iOS | Server time |

Rules for apps:

- Treat null as **unknown**. Show "syncing…", hide the time-dependent label, or show a neutral state.
- Never replace null with `DateTime.now()` in decision logic. If you need device time for something else (animations, logs), call `DateTime.now()` there directly.
- Use `onSyncChanged` (a `Stream<bool>`) to update the UI when the time arrives or is lost.
- The server stays the final authority: enforce anything that matters there.

What the package can't detect: a server or CDN whose own clock is wrong, and a `Date` header rewritten in transit (for example by a proxy on a rooted device).

## Choosing which requests to sample

Take the time only from your own backend, the authority for your app's decisions. Other servers (maps, payments, analytics, image CDNs) have their own clocks, and public cacheable endpoints can serve old copies.

Three optional filters decide, **before** a request is sent, whether its response is sampled. A request is sampled only if all three pass, so each filter can only remove requests, never add them back:

| Filter | Question it answers | Default |
| --- | --- | --- |
| `allow` | Does the URL match at least one entry? | Null: every URL |
| `deny` | Does the URL match no entry? | Null: no URL denied |
| `include` | Does your own function return true? | Null: every request |

Most apps only need `allow: ['https://api.myapp.com']`.

### allow and deny

Lists of URLs or paths:

```dart
ServerClockInterceptor(
  serverClock,
  allow: [
    'https://api.myapp.com',           // base URL: every path on that host
    'https://auth.myapp.com/v1/login', // URL with a path: that path and below
    '/api/v1/user',                    // path: on any host
  ],
  deny: ['/api/v1/public', 'https://api.myapp.com/v1/config'],
);
```

| Rule | Behaviour |
| --- | --- |
| Entries | A path (`/...`) matches on any host. A URL matches the same scheme, host and port, and its path and below |
| Path boundaries | Matching stops at `/`: `/api/user` matches `/api/user/42`, not `/api/users` |
| Normalisation | Host is case-insensitive, path is case-sensitive, a default port equals no port, a trailing `/` is ignored, the request's query and fragment are ignored |
| Which URL | The resolved request URL, so `baseUrl` + path and full URLs both work |
| Combining | `allow`, `deny` and `include` must all pass, so **deny always wins** |
| Defaults | `allow: null` allows every URL; `allow: []` allows none |
| Invalid entries | An empty entry, a URL without a scheme or host, or one with a query or fragment throws `ArgumentError` when the interceptor is created |

**Deny always wins**, whatever the order or how specific the entries are. With the setup above, `https://api.myapp.com/api/v1/public/feed` is allowed by `https://api.myapp.com` but denied by `/api/v1/public`, so it is not sampled. `deny` can only take URLs away, never add them.

### include

Your own yes/no function for rules a URL list can't express. It gets the request's `RequestOptions` (method, headers, `extra`, resolved `uri`) and returns true to sample the request, false to skip it. It runs after `allow` and `deny` pass.

| Need | `include:` |
| --- | --- |
| Only some methods | `(o) => o.method == 'GET'` |
| Only logged-in, per-user requests (not cached by CDNs) | `(o) => o.headers.containsKey('Authorization')` |
| Only in production builds (skip mock or staging servers) | `(_) => isProduction` |
| Skip one call site | `(o) => o.extra['skipClock'] != true`, then pass `Options(extra: {'skipClock': true})` on that call |
| Wildcard subdomains | `(o) => o.uri.host.endsWith('.myapp.com')` |

If `include` throws, the request goes through normally and only the sample is skipped.

`include` decides on the request, before it's sent; `cacheVerdict` (below) decides on the response, after it arrives.

### Which endpoints make good samples

Authenticated, user-specific responses, which CDNs don't cache (`Cache-Control: private` or `no-store`). Login is a good first sample: it is never cached and happens before any screen that needs the time.

## How samples are chosen

- The **newest** acceptable response wins.
- A response slower than `maxRoundTrip` (2 s) is ignored; without a valid time the limit is `maxRoundTripBeforeSync` (10 s), so a slow network still gets one.
- A response more than `tolerance` (5 s) **ahead** of `now` means the current time was stale: it replaces it at once.
- A response more than `tolerance` **behind** `now` is probably a cached copy: it is ignored. If three in a row agree with each other over more than twice `tolerance`, the server's clock really moved back, and the clock follows it. A cached copy can't do that, because its `Date` doesn't advance.

## Cached responses

A response is skipped when its headers show it came from a cache:

| Header | Treated as cached when |
| --- | --- |
| `Age` | Greater than 0 (`Age: 0` alone is not a hit) |
| `Cache-Status` (RFC 9211) | Any member has the `hit` parameter |
| `X-Cache` | CloudFront `Hit` / `RefreshHit`, Fastly or Varnish `HIT`, Squid `TCP_*_HIT` |
| `CF-Cache-Status` | Cloudflare `HIT`, `STALE`, `UPDATING`, `REVALIDATED` |

`304 Not Modified` responses are skipped too. `isCacheHit(headers)` is exported if you need the same check.

### Your own cache rules

Add `ServerClockInterceptor` after any caching interceptor. A cache that answers in its `onRequest` (like [dio_cache_plus](https://pub.dev/packages/dio_cache_plus)) never reaches it, and dio_cache_plus 2.1.0+ also marks hits with `Cache-Status` and `Age`, which are detected.

For anything else, pass `cacheVerdict`. It runs before the default check and returns a `CacheVerdict`:

| Verdict | Effect |
| --- | --- |
| `cached` | Skip the response, whatever its headers say |
| `fresh` | Sample it, skipping the default check (including `304`). Only when you know no cache answered |
| `useDefault` | The default check decides (`304` and `isCacheHit`) |

```dart
ServerClockInterceptor(
  serverClock,
  cacheVerdict: (response) {
    // Your offline cache marks its responses.
    if (response.extra['fromLocalCache'] == true) return CacheVerdict.cached;
    // Your CDN adds Age to live responses of this API.
    if (response.requestOptions.path.startsWith('/api/v1/user/')) {
      return CacheVerdict.fresh;
    }
    return CacheVerdict.useDefault;
  },
);
```

Anything the callback doesn't decide falls through to the default check, so it can't be lost by accident. A callback that throws counts as `cached`. To turn the default check off entirely, return `CacheVerdict.fresh` for every response; do that only if no cache sits between the app and your server.

Caches in the OS networking layer (for example NSURLCache or OkHttp behind a native Dio adapter) can return old responses without an `Age` header. Mark them with `cacheVerdict` if you can, and sample only `no-store` endpoints. `tolerance` rejects an old copy once the clock has a newer time, but not before the first sample.

### Interceptor order

The round trip is measured from this interceptor's `onRequest` to its `onResponse`. Adding it last keeps slow request work in other interceptors (token refresh, reading secure storage) out of the measurement.

## Sleep and app lifecycle

The time runs on the platform's boot clock, which keeps counting through deep sleep and can't be changed by the user:

| Platform | Clock | Counts deep sleep |
| --- | --- | --- |
| Android, Linux | `clock_gettime(CLOCK_BOOTTIME)` | Yes |
| iOS, macOS | `clock_gettime_nsec_np(CLOCK_MONOTONIC)` | Yes |
| Web, Windows, or if the boot clock fails | `Stopwatch` | No |

`countsSleep` tells you which one is in use. Call `invalidate()` when the app resumes: with a boot clock it does nothing, and without one it clears the time until the next response, because the clock may have paused while the device slept.

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) serverClock.invalidate();
}
```

The time lives in memory only. A new process starts with no time; nothing is saved to disk, because a stored offset would be wrong after a reboot.

## Accuracy

About ±1 second; a few seconds at worst on slow networks. `uncertainty` gives the worst-case error of the current sample: half the round trip plus half a second for the `Date` header's resolution. `onAnchor` emits a `ClockSample` for each accepted response, with `deviceSkew` (server minus device) for logging or a "your device time is off" banner.

## Fixed offsets

`nowIn(offset)` returns a `DateTime?` whose fields (hour, minute, weekday) are the wall-clock time at that offset. It is still flagged UTC, so read or format its fields, but never store it, send it, or call `toLocal()` on it. Store and send `now!.millisecondsSinceEpoch` instead.

Example: checking market hours in India Standard Time.

```dart
/// True or false, or null when the time is unknown.
bool? isMarketOpen(ServerClock serverClock) {
  final t = serverClock.nowIn(const Duration(hours: 5, minutes: 30));
  if (t == null) return null;
  if (t.weekday == DateTime.saturday || t.weekday == DateTime.sunday) {
    return false;
  }
  final minutes = t.hour * 60 + t.minute;
  return minutes >= 9 * 60 + 15 && minutes < 15 * 60 + 30;
}
```

Fixed offsets don't handle daylight saving time; for regions that use it, convert `now` with a timezone database.

## Web

Browsers hide the `Date` header on cross-origin requests. The server must send `Access-Control-Expose-Headers: Date`. Android, iOS and desktop are unaffected.

## API reference

The full reference, generated from the code comments, is on [pub.dev](https://pub.dev/documentation/dio_server_clock/latest/).

### ServerClock

```dart
ServerClock({
  Duration maxRoundTrip = const Duration(seconds: 2),
  Duration maxRoundTripBeforeSync = const Duration(seconds: 10),
  Duration tolerance = const Duration(seconds: 5),
})
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `maxRoundTrip` | 2 s | Slower samples are ignored while the clock has a time, so a slow response can't replace a better time |
| `maxRoundTripBeforeSync` | 10 s | Looser limit while the clock has no time, so a slow network still gets one |
| `tolerance` | 5 s | How far a sample may disagree with `now` before it counts as ahead (replaces the time) or behind (ignored as a cached copy). See [How samples are chosen](#how-samples-are-chosen) |

A negative duration throws `ArgumentError`.

| Member | What it gives or does |
| --- | --- |
| `now` | Server time in UTC, or null when there is no valid time |
| `nowIn(offset)` | Wall-clock fields at a fixed offset, or null. See [Fixed offsets](#fixed-offsets) |
| `isSynced` | `now != null` |
| `uncertainty` | Worst-case error of `now`: half the round trip plus half a second. Null with no time |
| `deviceSkew` | Server time minus device time; positive means the device clock is behind. Null with no time |
| `countsSleep` | Whether the clock keeps counting through deep sleep (see [Sleep and app lifecycle](#sleep-and-app-lifecycle)) |
| `onSyncChanged` | `Stream<bool>`: true when the time arrives, false when it's lost. Use it to rebuild "syncing…" UI |
| `onAnchor` | `Stream<ClockSample>`: every accepted sample, with `serverTime`, `roundTrip`, `uncertainty` and `deviceSkew`. For logging or a "your device time is off" banner |
| `invalidate()` | Call on app resume. Keeps the time where sleep is counted; clears it elsewhere |
| `reset()` | Forgets the time, for example after switching to another backend environment |
| `addHttpDate(header, roundTrip)` | Feeds a raw `Date` header, for responses outside Dio. Measure `roundTrip` with a `Stopwatch` and skip cached responses yourself |
| `addSample(serverTime, roundTrip, resolution:)` | Feeds a server time from elsewhere (a JSON field, a custom header) |
| `dispose()` | Closes the two streams; the clock keeps working. Not needed for an app-wide clock |

### ServerClockInterceptor

```dart
ServerClockInterceptor(
  ServerClock serverClock, {
  List<String>? allow,
  List<String>? deny,
  bool Function(RequestOptions options)? include,
  CacheVerdict Function(Response<dynamic> response)? cacheVerdict,
})
```

| Parameter | Runs | Default | Meaning |
| --- | --- | --- | --- |
| `allow` | Before the request | All URLs | Sample only URLs matching an entry. See [allow and deny](#allow-and-deny) |
| `deny` | Before the request | None | Never sample URLs matching an entry; always wins over `allow` |
| `include` | Before the request | All requests | Your own test on `RequestOptions`. See [include](#include) |
| `cacheVerdict` | After the response | Default check | Decides whether a response is a cached copy. See [Your own cache rules](#your-own-cache-rules) |

Add it last in `dio.interceptors`. Error responses (401, 500) are sampled too, because they come from the live server. It never throws while handling requests and never changes requests or responses; invalid `allow` or `deny` entries throw `ArgumentError` when it's created.

### Cache detection

- `CacheVerdict`: `cached`, `fresh` or `useDefault`, returned by `cacheVerdict`.
- `isCacheHit(headers)`: the default header check, for use outside the interceptor.

## Performance

Nothing runs in the background: no timers, threads or wake-ups, so there is no idle cost. Reading `now` is one monotonic clock read (tens of nanoseconds); each sampled response adds one header parse (about a microsecond). It's safe to read `now` in `build()`.

## Example app

[`example/`](example/) is a Flutter test app for Android and iOS: it shows the server time, device skew and an event log, and has a **Check** button for testing deep sleep on a real device. See [example/README.md](example/README.md).

## FAQ

**Why not NTP?** NTP needs UDP access to a time server, which some networks block, and it gives the time of a third party rather than your server. This package needs nothing beyond the requests you already make.

**Several backends?** Create one `ServerClock` and interceptor per `Dio` instance.

**Can I feed samples myself?** Yes: `addHttpDate(header, roundTrip)` or `addSample(serverTime, roundTrip, resolution: ...)`.
