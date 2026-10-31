import 'dart:async';

import 'package:clock/clock.dart';
import 'package:http_parser/http_parser.dart' show parseHttpDate;

import 'clock_sample.dart';
import 'monotonic.dart';

/// A clock anchored to server time: it gives a valid time or no time.
///
/// Feed it samples (usually through `ServerClockInterceptor`) and read the
/// time from [now] or [nowIn]. [now] is null until a sample is accepted, and
/// whenever the time can't be trusted. The device clock and timezone are
/// never used.
class ServerClock {
  /// Creates a clock with no time; [now] is null until the first sample.
  ///
  /// Throws an [ArgumentError] if a duration is negative.
  ServerClock({
    this.maxRoundTrip = const Duration(seconds: 2),
    this.maxRoundTripBeforeSync = const Duration(seconds: 10),
    this.tolerance = const Duration(seconds: 5),
  }) : _source = resolveMonotonicSource() {
    _checkNotNegative(maxRoundTrip, 'maxRoundTrip');
    _checkNotNegative(maxRoundTripBeforeSync, 'maxRoundTripBeforeSync');
    _checkNotNegative(tolerance, 'tolerance');
  }

  static void _checkNotNegative(Duration value, String name) {
    if (value.isNegative) throw ArgumentError.value(value, name, 'is negative');
  }

  /// Samples slower than this are ignored while the clock has a time.
  final Duration maxRoundTrip;

  /// Looser limit used while the clock has no time, so a slow network still
  /// gets one.
  final Duration maxRoundTripBeforeSync;

  /// How far a sample may disagree with [now] before it counts as ahead or
  /// behind.
  ///
  /// A sample more than this ahead means the current time was stale, so it
  /// replaces it. A sample more than this behind is probably a cached copy,
  /// so it is ignored, unless [behindSamplesToAccept] samples in a row agree
  /// with each other (the server's clock really moved back).
  final Duration tolerance;

  /// Behind samples that must agree before the clock follows them.
  static const int behindSamplesToAccept = 3;

  /// Resolution of the HTTP `Date` header.
  static const Duration httpDateResolution = Duration(seconds: 1);

  final MonotonicSource _source;

  // Server time and monotonic reading at the anchor, in microseconds.
  int? _anchorServerMicros;
  int _anchorMonoMicros = 0;
  Duration? _anchorUncertainty;

  // Recent samples behind [now], as (server micros, monotonic micros).
  final List<(int, int)> _behind = [];

  final _anchors = StreamController<ClockSample>.broadcast();
  final _syncChanges = StreamController<bool>.broadcast();

  /// Whether the clock has a valid time: the same as `now != null`.
  bool get isSynced => now != null;

  /// Fires every time a sample is accepted.
  Stream<ClockSample> get onAnchor => _anchors.stream;

  /// Fires true when the clock gets a time and false when it loses it
  /// ([reset], or [invalidate] where sleep isn't counted).
  Stream<bool> get onSyncChanged => _syncChanges.stream;

  /// Current server time in UTC, or null when there is no valid time.
  ///
  /// Null before the first accepted sample, after [reset], and after
  /// [invalidate] on platforms whose clock may pause in deep sleep, until the
  /// next sample. Treat null as "unknown"; don't replace it with
  /// `DateTime.now()` in decisions.
  DateTime? get now {
    final micros = _nowMicros();
    return micros == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  }

  int? _nowMicros() {
    final anchor = _anchorServerMicros;
    if (anchor == null) return null;
    final mono = _source.nowMicros();
    if (mono == null) return null;
    final elapsed = mono - _anchorMonoMicros;
    // A monotonic clock going backwards means it can't be trusted.
    if (elapsed < 0) return null;
    return anchor + elapsed;
  }

  /// Wall-clock fields at a fixed UTC offset (for IST: 5 h 30 min), or null
  /// when [now] is null.
  ///
  /// The returned value is still flagged UTC. Read its fields (hour, minute,
  /// weekday) or format it; never store it, send it, or call `toLocal()`.
  DateTime? nowIn(Duration utcOffset) => now?.add(utcOffset);

  /// Server time minus device time, or null when [now] is null.
  /// Positive means the device clock is behind.
  Duration? get deviceSkew => now?.difference(clock.now());

  /// Worst-case error of [now] when the current sample was accepted: half the
  /// round trip plus half the sample's resolution. Null when [now] is null.
  Duration? get uncertainty => isSynced ? _anchorUncertainty : null;

  /// Whether the clock keeps counting while the device is in deep sleep.
  ///
  /// True on Android, iOS, macOS and Linux (the platform boot clock); false
  /// on web and Windows, where [invalidate] clears the time.
  bool get countsSleep => _source.countsSleep;

  /// Adds a sample from a raw HTTP `Date` header value.
  ///
  /// Returns true if it was accepted; false if the header is not a valid HTTP
  /// date or the sample was rejected.
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
  /// how long the request took. Returns true if it was accepted.
  ///
  /// The newest acceptable sample becomes the time, except one more than
  /// [tolerance] behind [now] (see [tolerance]).
  bool addSample(
    DateTime serverTime,
    Duration roundTrip, {
    Duration resolution = Duration.zero,
  }) {
    if (roundTrip.isNegative || resolution.isNegative) return false;

    final mono = _source.nowMicros();
    if (mono == null) return false;

    final current = _nowMicros();
    final limit = current == null ? maxRoundTripBeforeSync : maxRoundTrip;
    if (roundTrip > limit) return false;

    // The server stamped the time somewhere in the round trip, and anywhere
    // in the resolution window; take the middle of both.
    final estimate =
        serverTime.microsecondsSinceEpoch +
        resolution.inMicroseconds ~/ 2 +
        roundTrip.inMicroseconds ~/ 2;

    if (current != null &&
        estimate < current - tolerance.inMicroseconds &&
        !_confirmsBehind(estimate, mono)) {
      return false;
    }

    _behind.clear();
    _anchorServerMicros = estimate;
    _anchorMonoMicros = mono;
    _anchorUncertainty = roundTrip ~/ 2 + resolution ~/ 2;

    if (current == null) _emitSync(true);
    if (!_anchors.isClosed) {
      _anchors.add(
        ClockSample(
          serverTime: DateTime.fromMicrosecondsSinceEpoch(
            estimate,
            isUtc: true,
          ),
          roundTrip: roundTrip,
          uncertainty: _anchorUncertainty!,
          deviceSkew: Duration(
            microseconds: estimate - clock.now().microsecondsSinceEpoch,
          ),
        ),
      );
    }
    return true;
  }

  /// Records a behind sample; true once [behindSamplesToAccept] in a row agree
  /// on the server time and span more than twice [tolerance].
  ///
  /// The span check rules out a cached copy: its `Date` doesn't advance, so
  /// copies read [tolerance] or more apart disagree.
  bool _confirmsBehind(int estimate, int mono) {
    _behind.add((estimate, mono));
    if (_behind.length > behindSamplesToAccept) _behind.removeAt(0);
    if (_behind.length < behindSamplesToAccept) return false;

    final (firstServer, firstMono) = _behind.first;
    final offset = firstServer - firstMono;
    final agree = _behind.every(
      (s) => (s.$1 - s.$2 - offset).abs() <= tolerance.inMicroseconds,
    );
    final span = _behind.last.$2 - firstMono;
    return agree && span > 2 * tolerance.inMicroseconds;
  }

  /// Call when the app resumes.
  ///
  /// Where the clock counts deep sleep ([countsSleep]), the time stays valid
  /// and this does nothing. Elsewhere the clock may have paused while the
  /// device slept, so the time is cleared until the next sample.
  void invalidate() {
    if (!_source.countsSleep) reset();
  }

  /// Forgets the time; [now] is null until the next sample.
  void reset() {
    final hadTime = _nowMicros() != null;
    _anchorServerMicros = null;
    _anchorUncertainty = null;
    _behind.clear();
    if (hadTime) _emitSync(false);
  }

  void _emitSync(bool synced) {
    if (!_syncChanges.isClosed) _syncChanges.add(synced);
  }

  /// Closes [onAnchor] and [onSyncChanged]. The clock keeps working
  /// afterwards.
  Future<void> dispose() async {
    await _anchors.close();
    await _syncChanges.close();
  }
}

/// The monotonic source a [ServerClock] uses, so the interceptor measures
/// round trips on the same clock. Not exported.
MonotonicSource monotonicSourceOf(ServerClock serverClock) =>
    serverClock._source;
