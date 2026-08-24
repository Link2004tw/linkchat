import 'dart:math' as math;

/// Exponential backoff for WebSocket reconnects.
///
/// Delays grow geometrically (base, base*2, base*4, …) capped at [maxDelay],
/// with jitter so multiple clients don't reconnect in lockstep. Call
/// [reset] once a connection is (re)established — the server's welcome
/// event is a good signal.
class ReconnectPolicy {
  ReconnectPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    math.Random? random,
  }) : _random = random ?? math.Random();

  final Duration baseDelay;
  final Duration maxDelay;
  final math.Random _random;

  /// Consecutive failed connection attempts since the last success.
  int _attempts = 0;

  /// Number of failed attempts since the last successful connection.
  /// 0 means connected (or never tried). Used for UI ("reconnecting, try 3").
  int get attempts => _attempts;

  /// Resets the backoff after a successful connection.
  void reset() {
    _attempts = 0;
  }

  /// The delay before the next attempt, based on how many attempts have
  /// already failed. Applies jitter in [0.5, 1.0] of the nominal delay.
  Duration nextDelay() {
    _attempts++;
    final exponent = math.min(_attempts - 1, 10);
    final nominal = baseDelay * math.pow(2, exponent);
    final capped = nominal > maxDelay ? maxDelay : nominal;
    final jitter = 0.5 + _random.nextDouble() * 0.5;
    return Duration(milliseconds: (capped.inMilliseconds * jitter).round());
  }
}
