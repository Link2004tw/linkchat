import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/core/markdown_util.dart';
import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/models/ws_event.dart';
import 'package:chat_app/providers/chat_list_provider.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

ChatMessage _text(
  String id,
  String content, {
  String? author,
  List<MentionUser> mentions = const [],
  bool mentionAll = false,
}) =>
    ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: author == null
          ? null
          : ChatUser(clerkId: 'clerk_$author', username: author),
      mentions: mentions,
      mentionAll: mentionAll,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ChatMessage mentions model', () {
    test('fromWs parses mentions and mentionAll', () {
      final m = ChatMessage.fromWs({
        'messageId': 'm1',
        'content': 'hey @bob',
        'mentions': [
          {'userId': 'u1', 'username': 'bob'},
        ],
        'mentionAll': false,
      });
      expect(m.mentions, hasLength(1));
      expect(m.mentions.first.userId, 'u1');
      expect(m.mentions.first.username, 'bob');
      expect(m.mentionAll, isFalse);
    });

    test('fromRest defaults absent mention fields', () {
      final m = ChatMessage.fromRest({'_id': 'm1', 'content': 'plain'});
      expect(m.mentions, isEmpty);
      expect(m.mentionAll, isFalse);
    });

    test('toJson round-trips mentions', () {
      final m = ChatMessage(
        id: 'm1',
        content: 'all @all',
        mentions: const [MentionUser(userId: 'u1', username: 'bob')],
        mentionAll: true,
      );
      final parsed = ChatMessage.fromWs(m.toJson());
      expect(parsed.mentions.single.username, 'bob');
      expect(parsed.mentionAll, isTrue);
    });

    test('mentionsMe matches a specific user and @all', () {
      final m = _text('m1', '@bob', mentions: const [
        MentionUser(userId: 'clerk_me', username: 'me'),
      ]);
      expect(m.mentionsMe('clerk_me'), isTrue);
      expect(m.mentionsMe('clerk_other'), isFalse);
      expect(_text('m2', '@all', mentionAll: true).mentionsMe('anyone'), isTrue);
    });
  });

  group('mentionizeMarkdown', () {
    test('wraps @username as a #mention link, preserving case', () {
      final out = mentionizeMarkdown('hey @Bob', const [
        MentionToken(name: 'bob', userId: 'u1'),
      ]);
      expect(out, 'hey [@Bob](#mention:u1)');
    });

    test('respects word boundaries (@bobby is not a mention of bob)', () {
      final out = mentionizeMarkdown('@bobby', const [
        MentionToken(name: 'bob', userId: 'u1'),
      ]);
      expect(out, '@bobby');
    });

    test('skips mentions inside code fences', () {
      final out = mentionizeMarkdown('```\n@bob\n```', const [
        MentionToken(name: 'bob', userId: 'u1'),
      ]);
      expect(out, contains('```\n@bob\n```'));
      expect(out, isNot(contains('#mention')));
    });

    test('wraps @all when the token is all', () {
      final out = mentionizeMarkdown('ping @all !', const [
        MentionToken(name: 'all', userId: 'all'),
      ]);
      expect(out, 'ping [@all](#mention:all) !');
    });

    test('escapes underscores in the label so they render literally', () {
      final out = mentionizeMarkdown('@a_b', const [
        MentionToken(name: 'a_b', userId: 'u1'),
      ]);
      expect(out, '[@a\\_b](#mention:u1)');
    });
  });

  group('ChatSummary mentionedCount', () {
    test('fromJson parses mentionedCount and copyWith carries it', () {
      final c = ChatSummary.fromJson({
        '_id': 'c1',
        'name': 'Room',
        'access': 'public',
        'unreadCount': 5,
        'mentionedCount': 2,
      });
      expect(c.mentionedCount, 2);
      expect(c.copyWith(mentionedCount: 0).mentionedCount, 0);
      expect(c.copyWith().mentionedCount, 2);
    });

    test('reduceChatList applies mentionedCount from both events', () {
      final chats = [ChatSummary(id: 'c1', name: 'R', access: 'public')];
      final afterNew = reduceChatList(chats, ChatListNewMessageEvent(
        chatId: 'c1',
        lastMessage: null,
        unreadCount: 4,
        mentionedCount: 3,
      ));
      expect(afterNew.single.mentionedCount, 3);

      final afterRead = reduceChatList(afterNew, ChatListUnreadUpdateEvent(
        chatId: 'c1',
        unreadCount: 0,
        mentionedCount: 0,
      ));
      expect(afterRead.single.mentionedCount, 0);
    });

    test('ChatListEvent.fromJson parses mentionedCount', () {
      final e = ChatListEvent.fromJson({
        'type': 'new-message',
        'chatId': 'c1',
        'mentionedCount': 7,
      });
      expect((e as ChatListNewMessageEvent).mentionedCount, 7);
    });
  });

  group('MessageBubble mentions', () {
    testWidgets('mentions render as underlined links', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '@bob', mentions: const [
          MentionUser(userId: 'u1', username: 'bob'),
        ]),
        isMine: false,
      )));
      expect(_hasLinkedSpan(tester, '@bob'), isTrue);
    });

    testWidgets('tapping a mention opens the member sheet', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '@bob', mentions: const [
          MentionUser(userId: 'u1', username: 'bob'),
        ]),
        isMine: false,
      )));
      await _tapSpanText(tester, '@bob');
      // The sheet opened: the user id subtitle is sheet-only, and the
      // mention title now appears twice (bubble link + sheet title).
      expect(find.text('u1'), findsOneWidget);
      expect(find.text('@bob'), findsNWidgets(2));
    });

    testWidgets("shows a 'mentioned you' chip on others' messages mentioning me",
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'hey @me', author: 'alice', mentions: const [
          MentionUser(userId: 'clerk_me', username: 'me'),
        ]),
        isMine: false,
        myUserId: 'clerk_me',
      )));
      expect(find.text('mentioned you'), findsOneWidget);
    });

    testWidgets('@all messages show the chip too, but never on my own messages',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '@all here', author: 'alice', mentionAll: true),
        isMine: false,
        myUserId: 'clerk_me',
      )));
      expect(find.text('mentioned you'), findsOneWidget);

      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m2', '@all here', mentionAll: true),
        isMine: true,
        myUserId: 'clerk_me',
      )));
      expect(find.text('mentioned you'), findsNothing);
    });

    testWidgets('no chip when the message does not mention me', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '@bob', author: 'alice', mentions: const [
          MentionUser(userId: 'u1', username: 'bob'),
        ]),
        isMine: false,
        myUserId: 'clerk_me',
      )));
      expect(find.text('mentioned you'), findsNothing);
    });
  });

  group('ChatInputBar @ picker', () {
    testWidgets('typing @ lists members and inserts @username on tap',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
        participants: const [
          RoomParticipant(clerkId: 'u1', username: 'bob', role: 'member'),
          RoomParticipant(clerkId: 'u2', username: 'carol', role: 'member'),
        ],
        myUserId: 'u9',
      )));

      await tester.enterText(find.byType(TextField), '@bo');
      await tester.pump();

      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('@carol'), findsNothing);

      await tester.tap(find.text('@bob'));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '@bob ');
    });

    testWidgets('group chats offer @all', (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
        participants: const [
          RoomParticipant(clerkId: 'u1', username: 'bob', role: 'member'),
          RoomParticipant(clerkId: 'u2', username: 'carol', role: 'member'),
        ],
        myUserId: 'u9',
      )));

      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();

      expect(find.text('@all'), findsOneWidget);

      await tester.tap(find.text('@all'));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '@all ');
    });

    testWidgets('DM (one other member) does not offer @all', (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
        participants: const [
          RoomParticipant(clerkId: 'u1', username: 'bob', role: 'member'),
        ],
        myUserId: 'u9',
      )));

      await tester.enterText(find.byType(TextField), '@');
      await tester.pump();

      expect(find.text('@all'), findsNothing);
      expect(find.text('@bob'), findsOneWidget);
    });
  });
}

/// True when any rendered [RichText] contains a span whose text equals [text]
/// and is underlined — i.e. the mention rendered as a markdown link.
bool _hasLinkedSpan(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (_spanHasUnderlined(rich.text, text)) return true;
  }
  return false;
}

bool _spanHasUnderlined(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text && span.style?.decoration == TextDecoration.underline) {
      return true;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (_spanHasUnderlined(child, text)) return true;
    }
  }
  return false;
}

/// Taps the [RichText] widget whose span tree contains [text].
Future<void> _tapSpanText(WidgetTester tester, String text) async {
  final rich = tester
      .widgetList<RichText>(find.byType(RichText))
      .firstWhere((r) => _spanContains(r.text, text));
  await tester.tap(find.byWidget(rich));
  await tester.pump();
}

bool _spanContains(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text) return true;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (_spanContains(child, text)) return true;
    }
  }
  return false;
}
