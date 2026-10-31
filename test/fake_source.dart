import 'package:dio_server_clock/src/monotonic.dart';

/// A monotonic clock the test moves by hand.
class FakeSource implements MonotonicSource {
  FakeSource({this.countsSleep = true});

  @override
  final bool countsSleep;

  int? micros = 1000000000;

  @override
  int? nowMicros() => micros;

  void advance(Duration d) => micros = micros! + d.inMicroseconds;
}
