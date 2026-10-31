import 'dart:async';

import 'package:clock/clock.dart';
import 'package:http_parser/http_parser.dart' show parseHttpDate;

import 'clock_sample.dart';
import 'monotonic.dart';

/// A clock anchored to server time.
///
/// Feed it samples (usually through `ServerClockInterceptor`) and read the
/// time from [now] or [nowIn]. After the first accepted sample, the device
/// clock and device timezone are no longer used for [now].
class ServerClock {
  /// Creates a clock with no anchor; [now] uses the device clock until the
  /// first sample is accepted.
  ///
  /// Throws an [ArgumentError] if a limit is negative.
  ServerClock({
    this.maxRoundTrip = const Duration(seconds: 2),
    this.maxRoundTripBeforeSync = const Duration(seconds: 10),
    this.maxAnchorAge = const Duration(minutes: 5),
  }) {
    if (maxRoundTrip.isNegative) {
      throw ArgumentError.value(maxRoundTrip, 'maxRoundTrip', 'is negative');
    }
    if (maxRoundTripBeforeSync.isNegative) {
      throw ArgumentError.value(
        maxRoundTripBeforeSync,
        'maxRoundTripBeforeSync',
        'is negative',
      );
    }
    if (maxAnchorAge.isNegative) {
      throw ArgumentError.value(maxAnchorAge, 'maxAnchorAge', 'is negative');
    }
  }

  /// Samples slower than this are ignored once the clock is synced.
  final Duration maxRoundTrip;

  /// Looser limit used until a sample is accepted, both before the first
  /// sync and after [invalidate], so a slow network still gets an anchor.
  final Duration maxRoundTripBeforeSync;

  /// After this long, any acceptable sample replaces the anchor even if it is
  /// less precise than the current one.
  final Duration maxAnchorAge;

  /// Resolution of the HTTP `Date` header.
  static const Duration httpDateResolution = Duration(seconds: 1);

  int? _anchorUtcMs;
  Duration? _anchorUncertainty;
  Stopwatch? _monotonic;
  bool _replaceNext = false;
  final _anchors = StreamController<ClockSample>.broadcast();

  /// Whether a sample has been accepted since creation or the last [reset].
  bool get isSynced => _anchorUtcMs != null;

  /// Fires every time a new anchor is set.
  Stream<ClockSample> get onAnchor => _anchors.stream;

  /// Current server time in UTC.
  ///
  /// Before the first sample this falls back to the device clock; check
  /// [isSynced] if that matters for your use case.
  DateTime get now {
    final anchor = _anchorUtcMs;
    if (anchor == null) return clock.now().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      anchor + _monotonic!.elapsedMilliseconds,
      isUtc: true,
    );
  }

  /// Wall-clock fields at a fixed UTC offset (for IST: 5 h 30 min).
  ///
  /// The returned value is still flagged UTC. Read its fields (hour, minute,
  /// weekday) or format it; never store it, send it, or call `toLocal()`.
  DateTime nowIn(Duration utcOffset) => now.add(utcOffset);

  /// Server time minus device time, or null before the first sample.
  /// Positive means the device clock is behind.
  Duration? get deviceSkew => isSynced ? now.difference(clock.now()) : null;

  /// Worst-case error of [now] at the moment the anchor was set: half the
  /// round trip plus half the resolution of the sample. Null before the first
  /// sample.
  Duration? get uncertainty => _anchorUncertainty;

  /// Adds a sample from a raw HTTP `Date` header value.
  ///
  /// Returns true if it became the new anchor; false if the header is not a
  /// valid HTTP date or the sample was rejected.
  bool addHttpDate(String dateHeader, Duration roundTrip) {
    final value = dateHeader.trim();
    DateTime serverTime;
    try {
      serverTime = parseHttpDate(value);
    } catch (_) {
      return false;
    }
    if (_rfc850Date.hasMatch(value)) {
      serverTime = _fixTwoDigitYear(serverTime);
    }
    return addSample(serverTime, roundTrip, resolution: httpDateResolution);
  }

  // Obsolete RFC 850 form with a two-digit year: `Friday, 30-Oct-26 ...`.
  static final _rfc850Date = RegExp(r'^[A-Za-z]+, \d{2}-[A-Za-z]{3}-\d{2} ');

  /// `parseHttpDate` reads a two-digit year as 19xx. RFC 9110 says to pick the
  /// latest year with those digits that is at most 50 years in the future.
  static DateTime _fixTwoDigitYear(DateTime parsed) {
    final latest = clock.now().toUtc().year + 50;
    var year = parsed.year;
    while (year + 100 <= latest) {
      year += 100;
    }
    return DateTime.utc(
      year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
    );
  }

  /// Adds a sample.
  ///
  /// [serverTime] is the time the server stamped on the response, truncated
  /// to [resolution] (one second for the HTTP `Date` header); [roundTrip] is
  /// how long the request took. Returns true if it became the new anchor.
  bool addSample(
    DateTime serverTime,
    Duration roundTrip, {
    Duration resolution = Duration.zero,
  }) {
    if (roundTrip.isNegative || resolution.isNegative) return false;

    final current = _anchorUncertainty;
    final mustReplace = current == null || _replaceNext;
    final limit = mustReplace ? maxRoundTripBeforeSync : maxRoundTrip;
    if (roundTrip > limit) return false;

    final uncertainty = roundTrip ~/ 2 + resolution ~/ 2;
    final anchorOld = _monotonic != null && _monotonic!.elapsed > maxAnchorAge;
    if (!mustReplace && !anchorOld && uncertainty >= current) return false;

    // The server stamped the time somewhere in the round trip, and anywhere
    // in the resolution window; take the middle of both.
    _anchorUtcMs =
        serverTime.millisecondsSinceEpoch +
        resolution.inMilliseconds ~/ 2 +
        roundTrip.inMilliseconds ~/ 2;
    _anchorUncertainty = uncertainty;
    _monotonic = startMonotonicStopwatch();
    _replaceNext = false;

    if (!_anchors.isClosed) {
      _anchors.add(
        ClockSample(
          serverTime: now,
          roundTrip: roundTrip,
          uncertainty: uncertainty,
          deviceSkew: deviceSkew!,
        ),
      );
    }
    return true;
  }

  /// Makes the next acceptable sample replace the anchor, using the looser
  /// [maxRoundTripBeforeSync] limit.
  ///
  /// Call when the app resumes: the monotonic clock may pause while the
  /// device is in deep sleep, so [now] can be behind until the next sample.
  /// [now] keeps running from the current anchor until then.
  void invalidate() {
    if (isSynced) _replaceNext = true;
  }

  /// Forgets the anchor entirely; [now] falls back to the device clock.
  void reset() {
    _anchorUtcMs = null;
    _anchorUncertainty = null;
    _monotonic = null;
    _replaceNext = false;
  }

  /// Closes the [onAnchor] stream. The clock keeps working afterwards.
  Future<void> dispose() => _anchors.close();
}
