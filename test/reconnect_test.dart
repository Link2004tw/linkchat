import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/reconnect_policy.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_room_provider.dart';

void main() {
  group('ReconnectPolicy', () {
    test('delays grow exponentially and cap at maxDelay', () {
      final policy = ReconnectPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 8),
        random: math.Random(1),
      );

      final d1 = policy.nextDelay();
      final d2 = policy.nextDelay();
      final d3 = policy.nextDelay();
      final d4 = policy.nextDelay();
      final d5 = policy.nextDelay();

      expect(policy.attempts, 5);
      // d1 ∈ [0.5s, 1s]; d2 ∈ [1s, 2s] — each step roughly doubles.
      expect(d1.inMilliseconds, lessThanOrEqualTo(1000));
      expect(d1.inMilliseconds, greaterThanOrEqualTo(500));
      expect(d2.inMilliseconds, lessThanOrEqualTo(2000));
      expect(d2.inMilliseconds, greaterThan(d1.inMilliseconds));
      expect(d3.inMilliseconds, lessThanOrEqualTo(4000));
      expect(d3.inMilliseconds, greaterThan(d2.inMilliseconds));
      expect(d4.inMilliseconds, lessThanOrEqualTo(8000));
      expect(d5.inMilliseconds, lessThanOrEqualTo(8000)); // capped at max
    });

    test('reset() clears the attempt counter', () {
      final policy = ReconnectPolicy(random: math.Random(2));
      policy.nextDelay();
      policy.nextDelay();
      expect(policy.attempts, 2);
      policy.reset();
      expect(policy.attempts, 0);
      // Backoff restarts from the base delay.
      final d1 = policy.nextDelay();
      expect(d1.inMilliseconds, lessThanOrEqualTo(1000));
    });
  });

  group('reconnect attempt surfacing', () {
    test('welcome system event resets reconnectAttempts to 0', () {
      final state = const ChatRoomState(reconnectAttempts: 3);
      final next = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(next.reconnectAttempts, 0);
      expect(next.isConnected, isTrue);
    });

    test('non-welcome system events keep reconnectAttempts', () {
      final state = const ChatRoomState(reconnectAttempts: 2);
      final next = applyChatEvent(
        state,
        const WsSystemEvent(type: 'join', text: 'alice joined'),
      );
      expect(next.reconnectAttempts, 2);
    });
  });

  group('connectionError surfacing', () {
    test('welcome clears the connection error', () {
      const state = ChatRoomState(
        connectionError: 'SocketException: Connection refused (ws://localhost:3001/ws/chat)',
      );
      final next = applyChatEvent(
        state,
        const WsSystemEvent(type: 'system', text: 'Welcome!'),
      );
      expect(next.connectionError, isNull);
      expect(next.isConnected, isTrue);
    });

    test('non-welcome system events keep the connection error', () {
      const state = ChatRoomState(connectionError: 'boom (ws://host/ws/chat)');
      final next = applyChatEvent(
        state,
        const WsSystemEvent(type: 'join', text: 'alice joined'),
      );
      expect(next.connectionError, 'boom (ws://host/ws/chat)');
    });

    test('copyWith can clear connectionError explicitly', () {
      const state = ChatRoomState(connectionError: 'boom');
      expect(state.copyWith(clearConnectionError: true).connectionError, isNull);
      // Without the clear flag the value is preserved.
      expect(state.copyWith().connectionError, 'boom');
    });
  });
}
