import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chat_app/models/chat.dart';
import 'package:chat_app/models/dictionary.dart';
import 'package:chat_app/models/message.dart';
import 'package:chat_app/models/user.dart';
import 'package:chat_app/providers/chat_room_provider.dart';
import 'package:chat_app/screens/chat_room_screen.dart';

ChatMessage _text(String id, String content, {String? author}) => ChatMessage(
      id: id,
      content: content,
      contentType: 'text',
      author: author == null ? null : ChatUser(clerkId: 'clerk_$author', username: author),
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A controller that returns a fixed room state instead of connecting to
/// the chat socket — lets screen-level tests exercise the UI with messages.
class _FakeRoomController extends ChatRoomController {
  _FakeRoomController(this._state);

  final ChatRoomState _state;

  @override
  ChatRoomState build(String chatId) => _state;
}

Widget _roomScreen(ChatRoomState state) => ProviderScope(
      overrides: [
        chatRoomProvider.overrideWith(() => _FakeRoomController(state)),
      ],
      child: MaterialApp(
        home: ChatRoomScreen(
          chat: ChatSummary(id: 'c1', name: 'Room', access: 'public'),
        ),
      ),
    );

void main() {
  group('MessageBubble', () {
    testWidgets('own message aligns right', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(message: _text('m1', 'hi'), isMine: true)));
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('other message aligns left and shows the username',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(message: _text('m1', 'yo', author: 'alice'), isMine: false)));
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerLeft);
      expect(find.text('alice'), findsOneWidget);
    });

    testWidgets('system message is rendered as a centered row',
        (tester) async {
      final system = ChatMessage(
        id: 'sys-1',
        content: 'alice joined the chat',
        contentType: 'system',
        event: 'join',
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: system, isMine: false)));
      expect(find.text('alice joined the chat'), findsOneWidget);
    });

    testWidgets('edited messages show the edited marker', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'v2', author: 'alice').copyWith(isEdited: true),
        isMine: false,
      )));
      expect(find.textContaining('edited'), findsOneWidget);
    });

    testWidgets('audio message renders a play button and voice label',
        (tester) async {
      // Rendering only — no audio I/O: the bubble's AudioPlayer is never
      // asked to play, so no platform channel is touched.
      final audio = ChatMessage(
        id: 'a1',
        content: 'https://res.cloudinary.com/x/video/upload/v1/voice-1.wav',
        contentType: 'audio',
        fileName: 'voice-1.wav',
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: audio, isMine: false)));
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      expect(find.text('Voice message'), findsOneWidget);
    });
  });

  group('MessageBubble markdown', () {
    testWidgets('renders heading, bold, italic and strikethrough',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '# Head **bold** *italic* ~~gone~~'),
        isMine: false,
      )));
      expect(find.textContaining('Head'), findsOneWidget);
      expect(find.textContaining('bold'), findsOneWidget);
      expect(find.textContaining('italic'), findsOneWidget);
      expect(find.textContaining('gone'), findsOneWidget);
    });

    testWidgets('renders a fenced code block', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '```\ncode here\n```'),
        isMine: false,
      )));
      expect(find.textContaining('code here'), findsOneWidget);
    });

    testWidgets('multi-line text keeps its line breaks', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'line one\nline two'),
        isMine: false,
      )));
      expect(_anyRichTextHas(tester, 'line one\nline two'), isTrue);
    });

    testWidgets('bare URLs render as underlined links', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'see https://example.com now'),
        isMine: false,
      )));
      expect(_hasLinkedUrl(tester, 'https://example.com'), isTrue);
    });

    testWidgets('chatapp:// invite links render as underlined links',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'join at chatapp://join/ABC123'),
        isMine: false,
      )));
      expect(_hasLinkedUrl(tester, 'chatapp://join/ABC123'), isTrue);
    });

    testWidgets('links on own bubbles use on-primary so they stay visible',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'see https://example.com now'),
        isMine: true,
      )));
      final bubble = tester.element(find.byType(MessageBubble));
      final scheme = Theme.of(bubble).colorScheme;
      expect(_linkColor(tester, 'https://example.com'), scheme.onPrimary);
    });

    testWidgets('links on other bubbles use the primary color',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'see https://example.com now'),
        isMine: false,
      )));
      final bubble = tester.element(find.byType(MessageBubble));
      final scheme = Theme.of(bubble).colorScheme;
      expect(_linkColor(tester, 'https://example.com'), scheme.primary);
    });

    testWidgets('URLs inside code fences are not links', (tester) async {
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '```\nhttps://example.com\n```'),
        isMine: false,
      )));
      expect(_hasLinkedUrl(tester, 'https://example.com'), isFalse);
      expect(find.textContaining('https://example.com'), findsOneWidget);
    });

    testWidgets('markdown renders immediately in a dictionary chat; '
        'tap still reveals meanings', (tester) async {
      final dict = [const DictEntry(code: 'm', meaning: 'Mark')];
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', '**hi** m'),
        isMine: false,
        dictEntries: dict,
      )));
      // No press needed: markdown is applied right away (no literal **),
      // the code word shows literally, and its meaning stays sealed.
      expect(find.textContaining('**hi**'), findsNothing);
      expect(find.textContaining('hi'), findsOneWidget);
      expect(find.textContaining('Mark'), findsNothing);

      await tester.tap(find.textContaining('hi'));
      await tester.pump();

      // Tapping still expands the code word to its meaning.
      expect(find.textContaining('Mark'), findsOneWidget);
    });
  });

  group('MessageBubble seen-by detail', () {
    testWidgets('caption lists readers oldest-first by read time',
        (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        content: 'hi',
        contentType: 'text',
        author: ChatUser(clerkId: 'me', username: 'me'),
        createdAt: DateTime.utc(2026, 1, 1, 11),
        seenBy: [
          // bob read later than carol — the caption must show carol first.
          SeenByUser(
            userId: 'bob',
            username: 'bob',
            lastReadAt: DateTime.utc(2026, 1, 1, 12),
          ),
          SeenByUser(
            userId: 'carol',
            username: 'carol',
            lastReadAt: DateTime.utc(2026, 1, 1, 10),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: msg, isMine: true)));
      expect(find.textContaining('Seen by 2'), findsOneWidget);
    });

    testWidgets("tapping 'Seen by' opens the reader detail with read times",
        (tester) async {
      final readAt = DateTime.utc(2026, 1, 1, 11);
      final msg = ChatMessage(
        id: 'm1',
        content: 'hi',
        contentType: 'text',
        author: ChatUser(clerkId: 'me', username: 'me'),
        createdAt: readAt,
        seenBy: [
          SeenByUser(userId: 'bob', username: 'bob', lastReadAt: readAt),
        ],
      );
      await tester.pumpWidget(_wrap(MessageBubble(message: msg, isMine: true)));
      expect(find.textContaining('Seen by 1'), findsOneWidget);

      await tester.tap(find.textContaining('Seen by 1'));
      await tester.pumpAndSettle();

      // Modal title “Seen by 1” + bubble label “Seen by 1” = 2 widgets.
      expect(find.text('Seen by 1'), findsNWidgets(2));
      // Exact read time (formatDate + formatTime from utils/format.dart).
      expect(find.textContaining('Read 1 Jan 2026'), findsOneWidget);
    });

    testWidgets('DM shows a simple Seen label instead of the reader list',
        (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        content: 'hi',
        contentType: 'text',
        author: ChatUser(clerkId: 'me', username: 'me'),
        seenBy: const [SeenByUser(userId: 'bob', username: 'bob')],
      );
      await tester.pumpWidget(_wrap(MessageBubble(
        message: msg,
        isMine: true,
        isDm: true,
      )));

      expect(find.text('Seen'), findsOneWidget);
      expect(find.textContaining('Seen by'), findsNothing);
    });

    testWidgets('DM shows Not seen until the other user reads',
        (tester) async {
      final msg = ChatMessage(
        id: 'm1',
        content: 'hi',
        contentType: 'text',
        author: ChatUser(clerkId: 'me', username: 'me'),
      );
      await tester.pumpWidget(_wrap(MessageBubble(
        message: msg,
        isMine: true,
        isDm: true,
      )));

      expect(find.text('Not seen'), findsOneWidget);
      // A group chat with no readers shows neither label.
      await tester.pumpWidget(_wrap(MessageBubble(
        message: msg,
        isMine: true,
      )));
      expect(find.text('Not seen'), findsNothing);
      expect(find.textContaining('Seen by'), findsNothing);
    });
  });

  group('MessageBubble long-press actions', () {
    testWidgets('own message offers delete for everyone (with confirm) and delete for me',
        (tester) async {
      String? deletedForEveryone;
      String? deletedForMe;
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'hi'),
        isMine: true,
        onDeleteForEveryone: (id) => deletedForEveryone = id,
        onDeleteForMe: (id) => deletedForMe = id,
      )));

      await tester.longPress(find.text('hi'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsOneWidget);

      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for everyone?'), findsOneWidget); // confirm

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deletedForEveryone, 'm1');
      expect(deletedForMe, isNull);
    });

    testWidgets("other person's message offers only delete for me",
        (tester) async {
      String? deletedForMe;
      await tester.pumpWidget(_wrap(MessageBubble(
        message: _text('m1', 'yo', author: 'alice'),
        isMine: false,
        onDeleteForMe: (id) => deletedForMe = id,
      )));

      await tester.longPress(find.text('yo'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsNothing);

      await tester.tap(find.text('Delete for me'));
      await tester.pumpAndSettle();
      expect(deletedForMe, 'm1');
    });

    testWidgets('image bubble offers save image', (tester) async {
      String? savedUrl;
      await tester.pumpWidget(_wrap(MessageBubble(
        message: ChatMessage(
          id: 'm1',
          content: 'https://img/x.jpg',
          contentType: 'image',
        ),
        isMine: true,
        onSaveImage: (url) => savedUrl = url,
      )));

      // The image placeholder spins forever, so pump fixed durations rather
      // than pumpAndSettle.
      await tester.longPress(find.byType(CachedNetworkImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // sheet animation
      expect(find.text('Save image'), findsOneWidget);

      await tester.tap(find.text('Save image'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(savedUrl, 'https://img/x.jpg');
    });

    testWidgets('pending messages offer no delete actions', (tester) async {
      final pending = ChatMessage(
        id: 'pending-1',
        pendingId: 'pending-1',
        content: 'hi',
        contentType: 'text',
      );
      await tester.pumpWidget(_wrap(MessageBubble(
        message: pending,
        isMine: true,
        onDeleteForMe: (_) {},
        onDeleteForEveryone: (_) {},
      )));

      await tester.longPress(find.text('hi'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for me'), findsNothing);
      expect(find.text('Delete for everyone'), findsNothing);
    });
  });

  group('MessageList', () {
    testWidgets('renders newest message first (reversed)', (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        messages: [
          _text('m1', 'first', author: 'alice'),
          _text('m2', 'second', author: 'bob'),
        ],
      );
      await tester.pumpWidget(_wrap(MessageList(state: state, me: ChatUser(clerkId: 'clerk_me', username: 'me'))));

      final bubbles = tester.widgetList<MessageBubble>(find.byType(MessageBubble)).toList();
      expect(bubbles, hasLength(2));
      // index 0 is the newest (bottom of the reversed list)
      expect(bubbles.first.message.id, 'm2');
      expect(bubbles.last.message.id, 'm1');
    });

    testWidgets('scrollTarget highlights and reveals the picked message',
        (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        messages: [
          _text('m1', 'first', author: 'alice'),
          _text('m2', 'second', author: 'bob'),
        ],
      );
      final target = ValueNotifier<String?>(null);
      addTearDown(target.dispose);
      await tester.pumpWidget(_wrap(MessageList(
        state: state,
        me: ChatUser(clerkId: 'clerk_me', username: 'me'),
        scrollTarget: target,
      )));

      target.value = 'm1';
      await tester.pump();
      // The highlight ring lands on the matching bubble and expires.
      final bubble = tester.widget<MessageBubble>(
        find.byType(MessageBubble).last,
      );
      expect(bubble.highlighted, isTrue);
      await tester.pump(const Duration(seconds: 3));
      final after = tester.widget<MessageBubble>(
        find.byType(MessageBubble).last,
      );
      expect(after.highlighted, isFalse);
    });
  });

  group('Message search', () {
    testWidgets('filters loaded messages and jumps to the picked result',
        (tester) async {
      final state = ChatRoomState(
        isLoading: false,
        isConnected: true,
        messages: [
          _text('m1', 'first hello', author: 'alice'),
          _text('m2', 'second message', author: 'bob'),
        ],
      );
      await tester.pumpWidget(_roomScreen(state));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      // 'e' is in both messages → both listed; 'hello' only in the first.
      await tester.enterText(find.byType(TextField).last, 'e');
      await tester.pump();
      expect(find.text('2 results'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'hello');
      await tester.pump();
      expect(find.text('1 result'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'zzz');
      await tester.pump();
      expect(find.text('No messages found'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'hello');
      await tester.pump();
      await tester.tap(find.ancestor(
        of: find.text('first hello'),
        matching: find.byType(ListTile),
      ));
      await tester.pumpAndSettle();

      // Jumping to the result reports the newest visible message, which
      // schedules a debounced read-ack timer; flush it so the test ends with
      // no pending timers.
      await tester.pump(const Duration(milliseconds: 600));

      // Sheet closed; the room is back (search result marker is gone).
      expect(find.text('1 result'), findsNothing);
    });
  });

  group('TypingBanner', () {
    testWidgets('shows a single user typing', (tester) async {
      await tester.pumpWidget(_wrap(TypingBanner(
        typingUserIds: {'u1'},
        onlineUsers: {'u1': const ChatUser(username: 'alice')},
      )));
      expect(find.text('alice is typing…'), findsOneWidget);
    });

    testWidgets('shows multiple users typing', (tester) async {
      await tester.pumpWidget(_wrap(TypingBanner(
        typingUserIds: {'u1', 'u2'},
        onlineUsers: {
          'u1': const ChatUser(username: 'alice'),
          'u2': const ChatUser(username: 'bob'),
        },
      )));
      expect(find.text('alice, bob are typing…'), findsOneWidget);
    });

    testWidgets('renders nothing when nobody is typing', (tester) async {
      await tester.pumpWidget(_wrap(const TypingBanner(typingUserIds: {}, onlineUsers: {})));
      expect(find.textContaining('typing'), findsNothing);
    });
  });

  group('ChatInputBar', () {
    testWidgets('calls onTyping as the user types', (tester) async {
      var typed = 0;
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () => typed++,
      )));

      await tester.enterText(find.byType(TextField), 'hello');
      expect(typed, greaterThan(0));
    });

    testWidgets('sends the text and clears the field', (tester) async {
      String? sent;
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (text) => sent = text,
        onTyping: () {},
      )));

      await tester.enterText(find.byType(TextField), '  hi there  ');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(sent, 'hi there'); // trimmed
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, isEmpty);
    });

    testWidgets('does not send empty text', (tester) async {
      var sends = 0;
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) => sends++,
        onTyping: () {},
      )));

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(sends, 0);
    });

    testWidgets('sends multi-line text, preserving internal newlines',
        (tester) async {
      String? sent;
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (text) => sent = text,
        onTyping: () {},
      )));

      await tester.enterText(find.byType(TextField), 'line one\nline two');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(sent, 'line one\nline two');
    });

    testWidgets('input expands to four lines for multi-line messages',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatInputBar(
        onSend: (_) {},
        onTyping: () {},
      )));

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.minLines, 1);
      expect(field.maxLines, 4);
      expect(field.textInputAction, TextInputAction.newline);
    });
  });
}

/// True when any rendered [RichText] contains a span whose text equals [url]
/// and is underlined — i.e. the URL rendered as a markdown link.
bool _hasLinkedUrl(WidgetTester tester, String url) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (_spanHasUrl(rich.text, url)) return true;
  }
  return false;
}

/// True when any rendered [RichText] concatenates its leaf spans to [text],
/// so the test can assert multi-line text keeps its `\n` (not merged into
/// spaces).
bool _anyRichTextHas(WidgetTester tester, String text) {
  String collect(InlineSpan span) {
    final buffer = StringBuffer();
    void visit(InlineSpan s) {
      if (s is TextSpan && s.text != null) buffer.write(s.text);
      if (s is TextSpan) {
        for (final child in s.children ?? const <InlineSpan>[]) {
          visit(child);
        }
      }
    }

    visit(span);
    return buffer.toString();
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (collect(rich.text) == text) return true;
  }
  return false;
}

bool _spanHasUrl(InlineSpan span, String url) {
  if (span is TextSpan) {
    final style = span.style;
    if (span.text == url && style?.decoration == TextDecoration.underline) {
      return true;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (_spanHasUrl(child, url)) return true;
    }
  }
  return false;
}

/// Color of the underlined link span for [url], or null when it isn't
/// rendered as a link.
Color? _linkColor(WidgetTester tester, String url) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final color = _spanUrlColor(rich.text, url);
    if (color != null) return color;
  }
  return null;
}

Color? _spanUrlColor(InlineSpan span, String url) {
  if (span is TextSpan) {
    if (span.text == url && span.style?.decoration == TextDecoration.underline) {
      return span.style?.color;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      final color = _spanUrlColor(child, url);
      if (color != null) return color;
    }
  }
  return null;
}
