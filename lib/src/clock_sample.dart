/// Emitted by [ServerClock.onAnchor] each time a new anchor is set.
class ClockSample {
  const ClockSample({
    required this.serverTime,
    required this.roundTrip,
    required this.uncertainty,
    required this.deviceSkew,
  });

  /// Best estimate of the server time (UTC) at the moment the anchor was set.
  final DateTime serverTime;

  /// Round trip of the request that produced the sample.
  final Duration roundTrip;

  /// Worst-case error of [serverTime].
  final Duration uncertainty;

  /// Server time minus device time at that moment.
  /// Positive means the device clock is behind.
  final Duration deviceSkew;

  @override
  String toString() =>
      'ClockSample(serverTime: $serverTime, roundTrip: $roundTrip, '
      'uncertainty: $uncertainty, deviceSkew: $deviceSkew)';
}
