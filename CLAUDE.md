# dio_server_clock

Pure Dart package: server-anchored time for Dio apps from the HTTP `Date` header. Published on pub.dev and meant for production apps (including ones that also use `dio_cache_plus`). Treat every change as production-critical.

## Commands
- `dart test`: unit tests (clock tests drive a `FakeSource` monotonic clock via `monotonicSourceOverride`; interceptor tests use a fake `HttpClientAdapter`). The platform-source tests check the real boot clock on macOS/Linux
- `dart analyze`: must report no issues
- `dart format lib test example`
- `dart pub publish --dry-run`: must report 0 warnings before a release
- Dio 4 check: create `pubspec_overrides.yaml` with `dependency_overrides: {dio: 4.0.0}`, run `dart pub get && dart analyze && dart test`, then delete it

## Invariants: don't break these
- **Valid time or no time**: `now` is the server time or null. Never fall back to the device clock; any doubt (no sample, monotonic clock unreadable or going backwards, `invalidate()` without sleep counting) means null.
- **Monotonic time**: always go through `MonotonicSource` (`lib/src/monotonic.dart`); the interceptor times round trips on the clock's own source (`monotonicSourceOf`). Never use `clock.stopwatch()`: `package:clock`'s stopwatch follows `clock.now()`, the device wall clock, which the user can change.
- **Boot clock (FFI)** (`monotonic_ffi.dart`): Android/Linux `clock_gettime(CLOCK_BOOTTIME=7)` with a `struct timespec` of two `Long`s (32-bit on 32-bit Android); iOS/macOS `clock_gettime_nsec_np(CLOCK_MONOTONIC=6)`, which counts sleep per Apple's man page (`CLOCK_UPTIME_RAW` doesn't). Any lookup failure or bad first reading falls back to `StopwatchSource` (`countsSleep` false). A wrong FFI signature can crash the process, so change these only with tests on real devices. `monotonic_stub.dart` is used where `dart:ffi` is missing (web).
- **Device clock**: `clock.now()` is used only for `deviceSkew` and the RFC 850 century fix. Never for `now`.
- **Sample choice**: newest acceptable sample wins; more than `tolerance` ahead replaces at once; more than `tolerance` behind is rejected unless `behindSamplesToAccept` (3) agree on offset and span more than 2 x `tolerance` (rules out a repeated cached copy).
- **Never throw from the interceptor** and never change requests or responses (other than removing its own `extra` key). Wrap user callbacks in try/catch.
- **Dio compatibility**: the pubspec allows Dio `>=4.0.0 <6.0.0`. Don't use Dio 5-only APIs in `lib/` (`DioException`, `Headers.value` is fine but throws on repeated headers, so use `headers[name]`). `onError`'s parameter type is left to inference so it works with `DioError` and `DioException`.
- **Cache detection**: a `Cache-Status` header alone is not a hit (`dio_cache_plus` adds `fwd=...` to every network response); only a `hit` parameter is. `Age: 0` alone is not a hit.
- **HTTP dates**: `parseHttpDate` reads RFC 850 two-digit years as 19xx; `addHttpDate` corrects them per RFC 9110.
- **No app-specific details**: no endpoints, hostnames or names from apps that use this package. The example uses a public, never-cached endpoint (`google.com/generate_204`); never a cacheable one (api.github.com's root is `public, max-age=60` and served an 8 s old `Date` without `Age`).
- **Public API**: everything exported from `lib/dio_server_clock.dart` is public. Don't remove or rename anything without a major version bump.

## Known limitations (intentional or deferred)
- Where sleep isn't counted (web, Windows), `now` is null after `invalidate()` until the next sample; without an `invalidate()` call on resume it would lag by the sleep time.
- Sleep counting on Android and iOS is verified by Apple's docs and Linux semantics, not yet by an automated test on devices.
- A cached response without `Age` or cache headers (seen on public, `max-age` responses) can't be detected; sample only private, per-user APIs. The `tolerance` rule rejects such a sample once the clock has a newer time.
- The round trip includes body download and other interceptors' response work.
- A server or CDN with a wrong clock can't be detected.

## CI
- `.github/workflows/ci.yml` runs on every PR and push to `main`: `verify` (format, `dart analyze --fatal-infos`, tests, publish dry run on Dart 3.9.2) and `compat` (the minimum Dart SDK 3.7.2, and Dio 4.0.0 via `pubspec_overrides.yaml`).
- Keep the SDK versions in `ci.yml` and `publish.yml` in sync; raise the `compat` SDK if the pubspec's minimum SDK changes.

## Releases
- Version bump in `pubspec.yaml`, CHANGELOG entry dated like `2026-Oct-31`, merged via a `release/vX.Y.Z` pull request. Keep user-facing changes under `## [Unreleased]` until then.
- Pushing a `vX.Y.Z` tag on `main` runs `.github/workflows/publish.yml`, which publishes to pub.dev after manual approval in the `pub.dev` environment, then creates the GitHub Release (title `X.Y.Z`, the version's CHANGELOG section, then a link to all code changes since the previous version; see `.github/scripts/`).
- Exception: pub.dev only allows automated publishing for a package that already exists, so `0.1.0` is published once by hand with `dart pub publish`. After that, never publish locally or create GitHub Releases by hand.
