import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';

Future<void> main() async {
  final serverClock = ServerClock();

  final dio = Dio(BaseOptions(baseUrl: 'https://www.google.com'))
    // Add it last, after auth and caching interceptors.
    ..interceptors.add(ServerClockInterceptor(serverClock));

  serverClock.onAnchor.listen((sample) => print('Anchored: $sample'));

  try {
    // A response that is never cached; prefer private, per-user APIs.
    await dio.get<dynamic>('/generate_204');
  } on Exception catch (_) {
    // Error responses still carry a Date header and are sampled.
  }

  print('Synced:      ${serverClock.isSynced}');
  print('Counts sleep: ${serverClock.countsSleep}');
  print('Server UTC:  ${serverClock.now}');
  print('Device skew: ${serverClock.deviceSkew}');
  print('Uncertainty: ${serverClock.uncertainty}');

  // A fixed offset, for example India Standard Time.
  const ist = Duration(hours: 5, minutes: 30);
  final t = serverClock.nowIn(ist);
  if (t == null) {
    // No valid time: show "syncing…" instead of guessing.
    print('IST:         unknown');
  } else {
    print('IST:         ${t.hour}:${t.minute.toString().padLeft(2, '0')}');
  }

  await serverClock.dispose();
}
