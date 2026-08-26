// Local-first storage foundation (PLAN-local-first.md leaf L1).
//
// A Drift/SQLite mirror of the user's chats and messages. The device DB is
// becoming the source of truth for the user's own history view; the server
// stays canonical for shared state until L3 wires live sync.
//
// Schema strategy: each row stores the model's FULL JSON payload (`toJson`)
// in a TEXT column, so round-trips are lossless — no TypeAdapters, no codegen
// on the models, and new backend fields ride along without a migration.
// Queries and sorts use typed index columns only; the payload is decoded on
// read. This deliberately mirrors `models/chat.dart` / `models/message.dart`
// 1:1 so repositories keep their public signatures.
//
// Hive stays for small KV only (dictionary cache, settings); ChatCache's
// room-page keys are retired at cutover (L6).

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/chat.dart';
import '../models/message.dart';

part 'local_db.g.dart';

/// One row of the chat list (`GET /chats/all` mirror). Server-canonical;
/// the client upserts whole rows and never merges partial updates.
class ChatListRows extends Table {
  /// Backend chat id (uuid or dmKey).
  TextColumn get id => text()();

  /// `updatedAt` from the summary, as epoch-ms — the server's change marker
  /// for delta sync later (C1 contract: `GET /chats?since=`).
  IntColumn get updatedAtMs => integer()();

  /// `lastMessage.sentAt` epoch-ms if present, else null. The list is
  /// displayed by recency of (lastMessageAtMs ?? updatedAtMs), mirroring
  /// `reduceChatList`'s sort.
  IntColumn get lastMessageAtMs => integer().nullable()();

  BoolColumn get isDm => boolean()();

  /// Indexed mirror flags so future UI can filter without decoding payloads.
  BoolColumn get mutedByUser => boolean()();

  /// Full [ChatSummary.toJson] JSON.
  TextColumn get payload => text()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [];
}

/// One message row across all chats. Mirrors what REST pages and (later,
/// L3) WS events deliver; pending/optimistic sends are never persisted.
class MessageRows extends Table {
  /// Server message id. Optimistic rows (`pending-…`) are skipped on write.
  TextColumn get id => text()();

  TextColumn get chatId => text()();

  /// Epoch-ms creation time — the keyset pagination field, matching the
  /// backend's `(createdAt, _id)` ordering (C1/smoke semantics).
  IntColumn get createdAtMs => integer()();

  /// Full [ChatMessage.toJson] JSON (decoded via `ChatMessage.fromWs`, the
  /// same path today's ChatCache room pages use).
  TextColumn get payload => text()();

  @override
  Set<Column> get primaryKey => {id};

  @TableIndex(name: 'msg_chat_time', columns: {#chatId, #createdAtMs})
}

/// A page of stored messages shaped like the server's response, so offline
/// fallback can stand in for `MessagePage` fields the DB can't know.
class StoredPage {
  const StoredPage({
    required this.messages,
    required this.more,
    this.nextCursor,
  });

  /// Chronological (oldest → newest), like `MessagePage.messages`.
  final List<ChatMessage> messages;

  /// True when older messages exist beyond this page.
  final bool more;

  /// The oldest shown message id when [more], else null — round-trips as
  /// the repository's `before` cursor exactly like the server's.
  final String? nextCursor;
}

@DriftDatabase(
  tables: [ChatListRows, MessageRows],
  daos: [ChatListDao, MessageDao],
)
class LocalDb extends _$LocalDb {
  /// Opens the app database on disk; tests inject `NativeDatabase.memory()`.
  LocalDb([QueryExecutor? executor]) : super(executor ?? _openConnection());

  static QueryExecutor _openConnection() => driftDatabase(name: 'chat_local');

  @override
  int get schemaVersion => 1;
}

int? _toEpochMs(DateTime? dt) => dt?.millisecondsSinceEpoch;

@driftAccessor
class ChatListDao extends DatabaseAccessor<LocalDb> with _$ChatListDaoMixin {
  ChatListDao(super.db);

  ChatListRowsCompanion _rowFor(ChatSummary chat) {
    final last = chat.lastMessage?.sentAt;
    return ChatListRowsCompanion.insert(
      id: chat.id,
      updatedAtMs: _toEpochMs(chat.updatedAt) ?? 0,
      lastMessageAtMs: Value(_toEpochMs(last ?? chat.updatedAt)),
      isDm: chat.isDm,
      mutedByUser: chat.mutedByUser,
      payload: jsonEncode(chat.toJson()),
    );
  }

  /// Upserts whole summaries (server wins per id). Partial lists are fine:
  /// rows not present stay untouched.
  Future<void> upsertChats(List<ChatSummary> chats) async {
    if (chats.isEmpty) return;
    await batch((b) {
      for (final chat in chats) {
        b.insert(chatListRows, _rowFor(chat), onConflict: DoUpdate((_) => _rowFor(chat)));
      }
    });
  }

  /// Replaces the entire list (a full `/chats/all` refresh): rows missing
  /// from [chats] are removed — the server's list IS the truth.
  Future<void> replaceAllChats(List<ChatSummary> chats) async {
    await batch((b) {
      b.deleteAll(chatListRows);
      for (final chat in chats) {
        b.insert(chatListRows, _rowFor(chat));
      }
    });
  }

  /// Removes one chat (leave/kick/deletion tombstone handling lives with
  /// the caller).
  Future<void> deleteChat(String chatId) =>
      (delete(chatListRows)..where((r) => r.id.equals(chatId))).go();

  /// The full list, newest-first by displayed recency
  /// (lastMessageAt ?? updatedAt), matching `_sortByRecency`.
  Future<List<ChatSummary>> all() async {
    final recency = coalesce([chatListRows.lastMessageAtMs, chatListRows.updatedAtMs]);
    final query = select(chatListRows)..orderBy([(u) => OrderingTerm.desc(recency)]);
    final rows = await query.get();
    return rows.map(_summaryFrom).toList();
  }

  ChatSummary _summaryFrom(ChatListRow row) =>
      ChatSummary.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
}

@driftAccessor
class MessageDao extends DatabaseAccessor<LocalDb> with _$MessageDaoMixin {
  MessageDao(super.db);

  MessageRowsCompanion _rowFor(ChatMessage m) => MessageRowsCompanion.insert(
        id: m.id!,
        chatId: m.chat ?? '',
        createdAtMs: _toEpochMs(m.createdAt) ?? 0,
        payload: jsonEncode(m.toJson()),
      );

  /// Persists real messages; skips optimistic rows (`pending-…`) and failed
  /// sends — same rule as today's ChatCache room pages. Deduplicates by id
  /// (server wins over any earlier copy).
  Future<void> upsertMessages(Iterable<ChatMessage> messages) async {
    final real = messages.where((m) => m.id != null && m.pendingId == null && !m.sendFailed);
    await batch((b) {
      for (final m in real) {
        b.insert(messageRows, _rowFor(m), onConflict: DoUpdate((_) => _rowFor(m)));
      }
    });
  }

  Future<int> countForChat(String chatId) async {
    final count = countAll(filter: messageRows.chatId.equals(chatId));
    final row = await (
      selectOnly(messageRows..where(messageRows.chatId.equals(chatId)))
        ..addColumns([count])
    ).getSingle();
    return row.read(count) ?? 0;
  }

  /// Newest page, newest-first internally then reversed to chronological.
  Future<StoredPage> newestPage(String chatId, int limit) async {
    final query = select(messageRows)
      ..where((r) => r.chatId.equals(chatId))
      ..orderBy([
            (r) => OrderingTerm.desc(r.createdAtMs),
            (r) => OrderingTerm.desc(r.id),
          ])
      ..limit(limit + 1);
    final docs = await query.get();
    final more = docs.length > limit;
    final page = more ? docs.sublist(0, limit) : docs;
    return StoredPage(
      messages: page.map(_messageFrom).toList().reversed.toList(),
      more: more,
      nextCursor: more && page.isNotEmpty ? page.last.id : null,
    );
  }

  /// Messages strictly older than [beforeId], using the same deterministic
  /// `(createdAtMs, id)` keyset bound as the backend's `before` pagination.
  Future<StoredPage> olderPage(String chatId, String beforeId, int limit) async {
    final cursor = await (select(messageRows)..where((r) => r.id.equals(beforeId)))
        .getSingleOrNull();
    if (cursor == null) {
      // Unknown cursor (e.g. pruned): serve the newest page rather than an
      // empty one — callers dedupe overlapping ids by id anyway.
      return newestPage(chatId, limit);
    }
    final query = select(messageRows)
      ..where(
        (r) =>
            r.chatId.equals(chatId) &
            (r.createdAtMs.isSmallerThanValue(cursor.createdAtMs) |
                (r.createdAtMs.equals(cursor.createdAtMs) & r.id.isSmallerThan(beforeId))),
      )
      ..orderBy([
            (r) => OrderingTerm.desc(r.createdAtMs),
            (r) => OrderingTerm.desc(r.id),
          ])
      ..limit(limit + 1);
    final docs = await query.get();
    final more = docs.length > limit;
    final page = more ? docs.sublist(0, limit) : docs;
    return StoredPage(
      messages: page.map(_messageFrom).toList().reversed.toList(),
      more: more,
      nextCursor: more && page.isNotEmpty ? page.last.id : null,
    );
  }

  ChatMessage _messageFrom(MessageRow row) =>
      ChatMessage.fromWs(jsonDecode(row.payload) as Map<String, dynamic>);
}
