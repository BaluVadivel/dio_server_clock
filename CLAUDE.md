# dio_server_clock

Pure Dart package: server-anchored time for Dio apps from the HTTP `Date` header. Published on pub.dev and meant for production apps (including ones that also use `dio_cache_plus`). Treat every change as production-critical.

## Commands
- `dart test`: unit tests (clock tests use `fake_async`; interceptor tests use a fake `HttpClientAdapter`)
- `dart analyze`: must report no issues
- `dart format lib test example`
- `dart pub publish --dry-run`: must report 0 warnings before a release
- Dio 4 check: create `pubspec_overrides.yaml` with `dependency_overrides: {dio: 4.0.0}`, run `dart pub get && dart analyze && dart test`, then delete it

## Invariants: don't break these
- **Monotonic time**: use `startMonotonicStopwatch()` (`lib/src/monotonic.dart`), never `clock.stopwatch()` directly. `package:clock`'s stopwatch follows `clock.now()`, the device wall clock, so a user changing device time would move the anchor.
- **Device clock**: `clock.now()` is used only before the first sample and for `deviceSkew`. Never for `now` once synced.
- **Never throw from the interceptor** and never change requests or responses (other than removing its own `extra` key). Wrap user callbacks in try/catch.
- **Dio compatibility**: the pubspec allows Dio `>=4.0.0 <6.0.0`. Don't use Dio 5-only APIs in `lib/` (`DioException`, `Headers.value` is fine but throws on repeated headers, so use `headers[name]`). `onError`'s parameter type is left to inference so it works with `DioError` and `DioException`.
- **Cache detection**: a `Cache-Status` header alone is not a hit (`dio_cache_plus` adds `fwd=...` to every network response); only a `hit` parameter is. `Age: 0` alone is not a hit.
- **HTTP dates**: `parseHttpDate` reads RFC 850 two-digit years as 19xx; `addHttpDate` corrects them per RFC 9110.
- **No app-specific details**: no real endpoints, hostnames or company names in the package, tests, example or README.
- **Public API**: everything exported from `lib/dio_server_clock.dart` is public. Don't remove or rename anything without a major version bump.

## Known limitations (intentional or deferred)
- After deep sleep, `now` lags by the sleep time until the next accepted sample; `invalidate()` only makes that sample replace the anchor.
- The round trip includes body download and other interceptors' response work.
- A server or CDN with a wrong clock can't be detected.

## CI
- `.github/workflows/ci.yml` runs on every PR and push to `main`: `verify` (format, `dart analyze --fatal-infos`, tests, publish dry run on Dart 3.9.2) and `compat` (the minimum Dart SDK 3.7.2, and Dio 4.0.0 via `pubspec_overrides.yaml`).
- Keep the SDK versions in `ci.yml` and `publish.yml` in sync; raise the `compat` SDK if the pubspec's minimum SDK changes.

## Releases
- Version bump in `pubspec.yaml`, CHANGELOG entry dated like `2026-Oct-31`, merged via a `release/vX.Y.Z` pull request. Keep user-facing changes under `## [Unreleased]` until then.
- Pushing a `vX.Y.Z` tag on `main` runs `.github/workflows/publish.yml`, which publishes to pub.dev after manual approval in the `pub.dev` environment, then creates the GitHub Release (title `X.Y.Z`, the version's CHANGELOG section, then a link to all code changes since the previous version; see `.github/scripts/`).
- Exception: pub.dev only allows automated publishing for a package that already exists, so `0.1.0` is published once by hand with `dart pub publish`. After that, never publish locally or create GitHub Releases by hand.
