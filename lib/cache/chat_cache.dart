import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/chat.dart';
import '../models/dictionary.dart';
import '../models/message.dart';

/// Minimal key-value storage behind the cache (a thin slice of Hive's
/// `Box`, so tests can substitute an in-memory implementation).
abstract class CacheStore {
  String? get(String key);

  Future<void> put(String key, String value);

  Future<void> clear();

  bool get isEmpty;
}

/// Hive-backed implementation.
class HiveCacheStore implements CacheStore {
  HiveCacheStore(this._box);

  final Box<String> _box;

  @override
  String? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, String value) => _box.put(key, value);

  @override
  Future<void> clear() => _box.clear();

  @override
  bool get isEmpty => _box.isEmpty;
}

/// In-memory implementation (used as the provider default in tests).
class MemoryCacheStore implements CacheStore {
  final Map<String, String> _data = {};

  @override
  String? get(String key) => _data[key];

  @override
  Future<void> put(String key, String value) async => _data[key] = value;

  @override
  Future<void> clear() async => _data.clear();

  @override
  bool get isEmpty => _data.isEmpty;
}

/// Opens a Hive box, retrying briefly when another process holds the file
/// lock. Returns `null` if the lock still can't be acquired (e.g. a second
/// instance of the app is running), so callers can fall back to in-memory
/// storage instead of crashing at startup.
///
/// Hive 2.x takes an exclusive OS-level lock (`flock`) on the box file when
/// opening it, and throws `FileSystemException: lock failed ... (errno 11)`
/// when that lock is already held. There is no opt-out for the lock in this
/// Hive version, so we degrade gracefully.
Future<Box<String>?> tryOpenHiveBox(String name) async {
  const maxAttempts = 3;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await Hive.openBox<String>(name);
    } catch (e) {
      final lockContended = e.toString().contains('lock failed');
      if (!lockContended) rethrow; // real I/O problem — surface it
      if (attempt == maxAttempts) return null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  return null;
}

/// The app's offline cache: the chat list + per-room messages, stored as
/// JSON strings (avoids Hive TypeAdapters/codegen entirely).
///
/// Keys: `chat_list` → the chat list; `room_<chatId>` → one room's
/// message page + pagination cursor.
class ChatCache {
  ChatCache(this._store);

  static const String _chatListKey = 'chat_list';
  static const String _roomPrefix = 'room_';
  static const String _dictPrefix = 'dict_';

  final CacheStore _store;

  bool get isEmpty => _store.isEmpty;

  /// Opens (or reopens) the Hive-backed cache. Call once from `main()`
  /// after `Hive.initFlutter()`.
  ///
  /// Falls back to an in-memory cache (no persistence) when the Hive box
  /// can't be locked — e.g. another instance of the app already has it open
  /// — so a lock hiccup never takes the app down at startup.
  static Future<ChatCache> open() async {
    final box = await tryOpenHiveBox('chat_cache');
    if (box == null) {
      debugPrint(
        'chat_cache: could not lock Hive box (another instance running?) — '
        'using in-memory cache',
      );
      return ChatCache.memory;
    }
    return ChatCache(HiveCacheStore(box));
  }

  /// An in-memory cache used as the provider default in tests.
  static ChatCache get memory => ChatCache(MemoryCacheStore());

  /// The last known chat list, or null when nothing was cached yet.
  List<ChatSummary>? readChatList() {
    final raw = _store.get(_chatListKey);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return null;
      return list
          .whereType<Map<String, dynamic>>()
          .map(ChatSummary.fromJson)
          .toList();
    } on FormatException {
      return null;
    }
  }

  /// Persists the chat list (replaces any previous entry).
  Future<void> writeChatList(List<ChatSummary> chats) {
    return _store.put(
      _chatListKey,
      jsonEncode([for (final chat in chats) chat.toJson()]),
    );
  }

  /// The last known messages + cursor for [chatId], or null.
  ({List<ChatMessage> messages, String? cursor, bool hasMore})?
      readRoom(String chatId) {
    final raw = _store.get('$_roomPrefix$chatId');
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final messages = map['messages'] is List
          ? (map['messages'] as List)
              .whereType<Map<String, dynamic>>()
              .map(ChatMessage.fromWs)
              .toList()
          : const <ChatMessage>[];
      return (
        messages: messages,
        cursor: map['cursor'] as String?,
        hasMore: map['hasMore'] as bool? ?? true,
      );
    } on FormatException {
      return null;
    }
  }

  /// Persists [messages] + pagination cursor for [chatId]. Optimistic
  /// (pending/failed) entries are skipped — they're transient.
  Future<void> writeRoom(
    String chatId, {
    required List<ChatMessage> messages,
    String? cursor,
    required bool hasMore,
  }) {
    final real = [
      for (final m in messages)
        if (m.pendingId == null) m.toJson(),
    ];
    return _store.put(
      '$_roomPrefix$chatId',
      jsonEncode({
        'messages': real,
        'cursor': cursor,
        'hasMore': hasMore,
      }),
    );
  }

  /// Clears everything (used on sign-out so one account's chats don't leak
  /// into the next).
  Future<void> clear() => _store.clear();

  /// Cached decrypted dictionary entries for [chatId] (offline fallback).
  /// The secret chat key is never persisted — only the decoded entries the
  /// user is already entitled to see on this device.
  List<Map<String, dynamic>>? readDictionary(String chatId) {
    final raw = _store.get('$_dictPrefix$chatId');
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return null;
      return list.whereType<Map<String, dynamic>>().toList();
    } on FormatException {
      return null;
    }
  }

  Future<void> writeDictionary(String chatId, List<DictEntry> entries) =>
      _store.put(
        '$_dictPrefix$chatId',
        jsonEncode([for (final e in entries) e.toJson()]),
      );
}
