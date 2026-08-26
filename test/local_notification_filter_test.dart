import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/services/chat_list_notification_router.dart';

void main() {
  bool notify({
    String? myClerkId = 'me_clerk',
    String? senderClerkId = 'other_clerk',
    bool chatIsMuted = false,
    bool appFocused = false,
  }) =>
      shouldNotifyLocally(
        myClerkId: myClerkId,
        senderClerkId: senderClerkId,
        chatIsMuted: chatIsMuted,
        appFocused: appFocused,
      );

  test('notifies for foreign senders when unfocused and unmuted', () {
    expect(notify(), isTrue);
  });

  test('never notifies about my own messages', () {
    expect(notify(senderClerkId: 'me_clerk'), isFalse);
  });

  test('muted chats stay silent (self-mute = notifications-only)', () {
    expect(notify(chatIsMuted: true), isFalse);
  });

  test('focused app stays silent (already reading)', () {
    expect(notify(appFocused: true), isFalse);
  });

  test('signed-out user still gets notified for others', () {
    expect(notify(myClerkId: null), isTrue);
    expect(notify(myClerkId: null, senderClerkId: null), isTrue);
  });

  test('unknown sender with known me is not treated as self', () {
    expect(notify(senderClerkId: null), isTrue);
  });
}
