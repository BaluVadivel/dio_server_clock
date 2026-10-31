/// An accepted sample, emitted by [ServerClock.onAnchor].
///
/// Each accepted response becomes the clock's new reference point. Use it
/// for logging, metrics, or a "your device time is off" banner based on
/// [deviceSkew].
class ClockSample {
  /// Creates a sample. The clock creates these; you only need this in tests.
  const ClockSample({
    required this.serverTime,
    required this.roundTrip,
    required this.uncertainty,
    required this.deviceSkew,
  });

  /// Best estimate of the server time (UTC) when the response arrived:
  /// the `Date` header plus half the round trip and half a second.
  final DateTime serverTime;

  /// Round trip of the request that produced the sample.
  final Duration roundTrip;

  /// Worst-case error of [serverTime]: half the round trip plus half the
  /// `Date` header's one-second resolution.
  final Duration uncertainty;

  /// Server time minus device time at that moment.
  /// Positive means the device clock is behind.
  final Duration deviceSkew;

  @override
  String toString() =>
      'ClockSample(serverTime: $serverTime, roundTrip: $roundTrip, '
      'uncertainty: $uncertainty, deviceSkew: $deviceSkew)';
}
