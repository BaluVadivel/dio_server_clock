import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_server_clock/dio_server_clock.dart';
import 'package:flutter/material.dart';

/// Test app for dio_server_clock on a real device.
///
/// Sleep test: tap Sample, lock the phone for 15 minutes or more, unlock,
/// then tap Check before anything else. The clock should be within about a
/// second of the server.
void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dio_server_clock',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const ClockPage(),
    );
  }
}

const _ist = Duration(hours: 5, minutes: 30);

/// A public endpoint that is never cached, so its `Date` is always fresh.
const _url = 'https://www.google.com/generate_204';

class ClockPage extends StatefulWidget {
  const ClockPage({super.key});

  @override
  State<ClockPage> createState() => _ClockPageState();
}

class _ClockPageState extends State<ClockPage> with WidgetsBindingObserver {
  // The shared clock, fed by a default interceptor: the setup most apps use.
  final _clock = ServerClock.instance;
  late final _dio = Dio()..interceptors.add(ServerClockInterceptor());
  final _log = <String>[];
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _ticker;

  bool _sampleOnResume = false;
  bool _busy = false;
  String? _checkResult;

  // Clock readings when the app was paused, to compare on resume.
  DateTime? _pausedServer;
  DateTime? _pausedDevice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _subscriptions
      ..add(
        _clock.onAnchor.listen(
          (s) => _addLog(
            'Accepted: server ${_time(s.serverTime.add(_ist))} IST, '
            'round trip ${_seconds(s.roundTrip)}, '
            'device skew ${_seconds(s.deviceSkew)}',
          ),
        ),
      )
      ..add(
        _clock.onSyncChanged.listen(
          (synced) => _addLog(synced ? 'Time gained' : 'Time lost'),
        ),
      );
    _addLog(
      _clock.countsSleep
          ? 'Clock counts deep sleep (boot clock)'
          : 'Clock may pause in deep sleep (stopwatch fallback)',
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _dio.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Android can report paused again (screen on, lock screen) before
      // resumed; keep the first one so "away" covers the whole time.
      if (_pausedDevice == null) {
        _pausedServer = _clock.now;
        _pausedDevice = DateTime.now();
      }
      _addLog('Paused');
    } else if (state == AppLifecycleState.resumed) {
      _clock.invalidate();
      _logResume();
      if (_sampleOnResume) _sample();
    }
  }

  void _logResume() {
    final pausedDevice = _pausedDevice;
    final pausedServer = _pausedServer;
    _pausedDevice = null;
    _pausedServer = null;
    if (pausedDevice == null) return _addLog('Resumed');

    final byDevice = DateTime.now().difference(pausedDevice);
    final now = _clock.now;
    if (pausedServer == null || now == null) {
      return _addLog('Resumed after ${_seconds(byDevice)} (device clock)');
    }
    final byServer = now.difference(pausedServer);
    _addLog(
      'Resumed: away ${_seconds(byDevice)} by device clock, '
      '${_seconds(byServer)} by server clock',
    );
    // Only meaningful if the device time wasn't changed while away.
    if ((byDevice - byServer).abs() > const Duration(seconds: 2)) {
      _addLog(
        'Warning: the server clock missed ${_seconds(byDevice - byServer)}; '
        'tap Check',
      );
    }
  }

  Future<void> _sample() async {
    setState(() => _busy = true);
    try {
      final response = await _dio.get<dynamic>(_url);
      _logResponse(response);
    } on DioException catch (e) {
      final response = e.response;
      if (response != null) {
        _logResponse(response);
      } else {
        _addLog('Request failed: ${e.message ?? e.type.name}');
      }
    } catch (e) {
      _addLog('Request failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _logResponse(Response<dynamic> response) {
    final cached = isCacheHit(response.headers);
    _addLog(
      'GET: ${response.statusCode}, '
      'Date ${response.headers['date']?.join(', ') ?? 'missing'}'
      '${cached ? ' (cached, skipped)' : ''}',
    );
  }

  /// Asks the server for the time without feeding the main clock, and
  /// compares.
  Future<void> _check() async {
    setState(() {
      _busy = true;
      _checkResult = null;
    });
    // Its own clock, so the check never feeds or reads the shared one.
    final probe = ServerClock();
    final probeDio =
        Dio()..interceptors.add(ServerClockInterceptor(serverClock: probe));
    try {
      await probeDio.get<dynamic>(_url);
    } catch (_) {
      // Error responses are still sampled; failures leave probe empty.
    }
    final fresh = probe.now;
    final mine = _clock.now;
    String result;
    if (fresh == null) {
      result = 'Check failed: no usable response (offline, slow or cached)';
    } else if (mine == null) {
      result =
          'No time on the clock; the server says '
          '${_time(fresh.add(_ist))} IST';
    } else {
      final off = mine.difference(fresh);
      final ok = off.abs() <= const Duration(seconds: 2);
      result =
          '${ok ? 'OK' : 'OFF'}: the clock is ${_seconds(off)} from the '
          'server (± ${_seconds(probe.uncertainty)})';
    }
    _addLog('Check: $result');
    probeDio.close();
    await probe.dispose();
    if (mounted) {
      setState(() {
        _busy = false;
        _checkResult = result;
      });
    }
  }

  void _addLog(String message) {
    // Requests can finish after the page is gone.
    if (!mounted) return;
    final stamp = _time(_clock.nowIn(_ist));
    // Also in the device log (adb logcat, flutter run), for scripted tests.
    debugPrint('DSC $stamp  $message');
    setState(() {
      _log.insert(0, '$stamp  $message');
      if (_log.length > 200) _log.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = _clock.now;
    final device = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('dio_server_clock')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    now == null ? 'Syncing…' : '${_time(now.add(_ist))} IST',
                    style: theme.textTheme.displaySmall,
                  ),
                  Text(
                    now == null
                        ? 'No valid server time'
                        : '${_time(now)} UTC, ± ${_seconds(_clock.uncertainty)}',
                  ),
                  const Divider(height: 24),
                  _row(
                    'Device time',
                    '${_time(device)} (${device.timeZoneName})',
                  ),
                  _row('Device skew', _seconds(_clock.deviceSkew)),
                  _row(
                    'Counts deep sleep',
                    _clock.countsSleep ? 'Yes (boot clock)' : 'No (stopwatch)',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Endpoint: $_url', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _sample,
                child: const Text('Sample'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _check,
                child: const Text('Check'),
              ),
              OutlinedButton(
                onPressed: () {
                  _clock.invalidate();
                  _addLog('Invalidated');
                },
                child: const Text('Invalidate'),
              ),
              OutlinedButton(
                onPressed: () {
                  _clock.reset();
                  _addLog('Reset');
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          if (_checkResult != null) ...[
            const SizedBox(height: 8),
            Text(_checkResult!, style: theme.textTheme.titleMedium),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sample on resume'),
            subtitle: const Text('Keep off for the sleep test'),
            value: _sampleOnResume,
            onChanged: (v) => setState(() => _sampleOnResume = v),
          ),
          Text(
            'Sleep test: tap Sample, lock the phone for 15+ minutes, unlock, '
            'then tap Check first.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Log', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_log.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(line, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

/// HH:mm:ss of the fields as they are; '--:--:--' when null.
String _time(DateTime? t) =>
    t == null
        ? '--:--:--'
        : '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _seconds(Duration? d) =>
    d == null ? '—' : '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
