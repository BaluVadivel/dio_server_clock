# dio_server_clock example

A Flutter test app (Android and iOS) for checking the clock on a real device: sync, device time changes and deep sleep. The code is in [`lib/main.dart`](lib/main.dart).

## Setup

```dart
final dio = Dio()..interceptors.add(ServerClockInterceptor());

// On AppLifecycleState.resumed:
ServerClock.instance.invalidate();

final now = ServerClock.instance.now; // null = no valid time; show "syncing…"
```

## Run it

```bash
cd example
flutter run
```

For a 32-bit Android device: `flutter build apk --target-platform android-arm`, then install the APK.

## What to test

| Test | Steps | Expected |
| --- | --- | --- |
| Sync | Tap **Sample** | The time appears; the log shows `Accepted` |
| Device time | Change the phone's time or timezone, come back | Server time and IST don't change; device skew does |
| Deep sleep | Tap **Sample**, lock the phone for 15+ minutes, unlock, tap **Check** first | `OK`, within about a second |
| No time | Tap **Reset** | "Syncing…" until the next sample |

Keep **Sample on resume** off for the sleep test, so a request doesn't hide the result.

The app samples `https://www.google.com/generate_204`, a public endpoint that is never cached. The time and the log live in memory only; they are reset if the OS closes the app.
