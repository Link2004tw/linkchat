import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/chats_repository.dart';
import '../repositories/dictionary_repository.dart';
import '../repositories/friends_repository.dart';
import '../repositories/messages_repository.dart';
import '../repositories/user_repository.dart';
import '../services/dictionary_crypto.dart';
import 'auth_providers.dart';

/// Typed repositories, built on the shared [apiClientProvider].
///
/// Screens use these with `ref.watch(...)`; no screen should touch
/// [ApiClient] or raw HTTP directly.

final chatsRepositoryProvider = Provider<ChatsRepository>(
  (ref) => ChatsRepository(ref.watch(apiClientProvider)),
);

final messagesRepositoryProvider = Provider<MessagesRepository>(
  (ref) => MessagesRepository(ref.watch(apiClientProvider)),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(ref.watch(apiClientProvider)),
);

final friendsRepositoryProvider = Provider<FriendsRepository>(
  (ref) => FriendsRepository(ref.watch(apiClientProvider)),
);

/// Etc-wrapped access to the dictionary crypto primitives.
final dictionaryCryptoProvider = Provider<DictionaryCrypto>(
  (ref) => DictionaryCrypto(),
);

final dictionaryRepositoryProvider = Provider<DictionaryRepository>(
  (ref) => DictionaryRepository(ref.watch(apiClientProvider)),
);
