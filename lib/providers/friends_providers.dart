import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/friend.dart';
import '../models/friend_request.dart';
import 'repository_providers.dart';

/// The friends list (`GET /user/friends`). Each friend carries a `dmChatId`
/// (auto-created by the backend), so opening a DM is a single tap.
///
/// Invalidate after accepting a request, removing a friend, etc.
final friendsProvider = FutureProvider.autoDispose<List<Friend>>((ref) async {
  return ref.watch(friendsRepositoryProvider).getFriends();
});

/// Pending friend requests (`GET /user/friends/requests`) — incoming and
/// outgoing. Invalidate after accept/decline/cancel.
final friendRequestsProvider =
    FutureProvider.autoDispose<FriendRequests>((ref) async {
  return ref.watch(friendsRepositoryProvider).getRequests();
});
