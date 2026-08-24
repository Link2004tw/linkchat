# Flutter Chat App — Tasks

MVP scope: Core chat · Media sharing · Presence + typing · **Friends & DMs** (Option A — backend friend-gating kept as-is).

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Verify Flutter toolchain | Check `flutter --version`, `dart`, and an Android SDK/emulator are available on the dev machine before scaffolding | High | Easy |
| 2 | Enable native platform in Clerk | ⚠️ USER ACTION: enable Native in the Clerk dashboard, add package `com.example.chat_app`, copy the publishable key | In the Clerk dashboard, enable the Native platform for the instance, add the Android package name, and copy the publishable key into the app config | High | Easy |
| 3 | ✅ Configure Android manifest | Add `INTERNET` permission and `usesCleartextTraffic="true"` (dev only) so the app can talk to the plain-HTTP backend | High | Easy |
| 4 | ✅ Scaffold Flutter project | Run `flutter create` in `flutter-app/` with the Android platform, then add dependencies: `clerk_flutter`, `flutter_riverpod`, `web_socket_channel`, `http`, `cached_network_image`, `image_picker`/`file_picker`, `intl` | High | Easy |
| 5 | ✅ Core structure + config | Create `core/config.dart` with `--dart-define=API_HOST` (emulator `10.0.2.2`, device LAN IP), `core/api_client.dart`, and `core/ws_client.dart` skeletons | High | Medium |
| 6 | ✅ JSON models + shape normalization | Dart models for Chat, Message, User, Friend and WS event types; normalize backend quirks: `profileImageUrl`/`imageUrl`, epoch-ms vs ISO timestamps, `replyTo` id-or-object, nullable `fileSize`/`isEdited` | High | Medium |
| 7 | ✅ Clerk sign-in flow | Integrate the official Clerk Flutter SDK: auth scope, sign-in/sign-up screen, session token via `getToken()` | High | Medium |
| 8 | ✅ Auth provider + token wiring | Riverpod auth provider holding the JWT; feed it into `api_client` (Bearer header) and `ws_client` (`?token=`); refresh on token change | High | Medium |
| 9 | ✅ User bootstrap after sign-in | Right after sign-in call `GET /api/chats/all` (triggers `getOrCreateUserById` to create the local user). Avoid `/api/auth/me` — it creates users with `userId: undefined` | High | Easy |
| 10 | ✅ Chat list screen + REST | Fetch `GET /chats/all`, render list with avatar, last message preview and unread badge; pull-to-refresh | High | Medium |
| 11 | ✅ Chat WebSocket service | Connect `/ws/chat?chatId&token` per room; handle inbound `message`, `edit`, `delete`, `typing`, `presence`, system events; send `message`, `edit`, `delete`, `typing`. All message sends go over WS — REST `POST /chats/:id/messages` returns ciphertext and doesn't broadcast | High | Hard |
| 12 | ✅ Chat-list WebSocket | Connect `/ws/chat-list?token`; apply live `new-message` and `unread-update` to the list; send `mark-read` when opening a room | High | Medium |
| 13 | ✅ Chat room screen | Message bubbles (own vs others, avatars, timestamps), system-event rows (`join`/`leave`/`kick`/`invite` use `text`), typing indicator, online members in header; wire to the chat provider | High | Medium |
| 14 | ✅ Message pagination | Infinite scroll up using `GET /chats/:id/messages?limit&before`; derive the initial `before` cursor from the oldest WS-history `messageId` (WS history is fixed at 50 with no cursor) | Medium | Medium |
| 15 | ✅ Create room / join room | Screens and actions: create group (`POST /chats`), search public rooms (`GET /chats/search`), join (`POST /chats/:id/join`) | Medium | Medium |
| 16 | ✅ Friends list + DM shortcut | `GET /api/user/friends` (each friend includes `dmChatId` — DM auto-created); friends screen with avatar + name; tap opens the DM chat room directly | Medium | Medium |
| 17 | ✅ User search + send/cancel requests | Global search `GET /api/user/search?q=` (shows `friendRequestStatus`); send request `POST /api/user/friends`; cancel own `DELETE /api/user/friends/requests/:id` | Medium | Medium |
| 18 | ✅ Incoming requests accept/decline | `GET /api/user/friends/requests` (ingoing + outgoing lists); accept `PUT .../requests/:id/accept`, decline `PUT .../requests/:id/decline`; refresh friends + chat list after accept | Medium | Medium |
| 19 | ✅ Remove friend | `DELETE /api/user/friends/:clerkId` with confirm dialog | Low | Easy |
| 20 | ✅ WS file upload protocol | Pick image/file, send `file-start` + binary chunks, handle `file-progress` and `file-complete`; keep ~6 MB cap (server cap is 10 MB) | Medium | Hard |
| 21 | ✅ Upload progress UI | Progress bar on outgoing media messages driven by `file-progress` events; failure handling | Medium | Medium |
| 22 | ✅ Render media messages | Inline images via `cached_network_image`, file cards with tap-to-open, captions | Medium | Medium |
| 23 | ✅ Presence indicators | Online dots on avatars and live member count using `presence` events + snapshot | Medium | Easy |
| 24 | ✅ Typing indicator polish | Debounced typing sends (e.g. every 3 s) and "X is typing…" banner | Low | Easy |
| 25 | ✅ WS reconnect + token refresh | Auto-reconnect with backoff on non-1000 close; re-fetch a fresh Clerk token before reconnecting | Medium | Hard |
| 26 | ✅ Error/empty states + optimistic sends | Snackbars/toasts on failures, empty-list states, optimistic message send with retry on WS failure | Low | Medium |
| 27 | ✅ Local caching | Persist chat list and last messages with Hive/Drift for offline launch | Low | Hard |
| 28 | ✅ Push notifications (implemented, needs your Firebase setup) | FCM-based notifications for new messages while the app is backgrounded (WS doesn't run in background). Backend done (register + send); Flutter packages added + wiring file ready (`services/push_wiring.dart`) — enable via the `[PUSH]` markers after `flutterfire configure` | Low | Hard |

## Phase 1 — Backend: encrypted per-chat dictionary API

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 29 | ✅ User schema: device public key | Add `encPublicKey` (string) + `encPublicKeyVersion` (number) to `IUser` in `schema/user.schema.ts`; include in the schema definition | High | Easy |
| 30 | ✅ Chat schema: dictionary + wraps | Add embedded `dictionary` (`ciphertext`/`iv`/`authTag`/`version`) and `dictionaryWraps` subdocs (`user` ref, `deviceKeyVersion`, `encKey`/`iv`/`authTag`/`wrapPub`) to `schema/chat.schema.ts` | High | Medium |
| 31 | ✅ Dictionary service | New `services/dictionary.service.ts`: `getDictionary(chatId)` (returns blob + wraps + participant pubkeys) and `saveDictionary(chatId, payload)` with participant-membership checks; keep blobs opaque, validate rough size. Never decrypts | High | Medium |
| 32 | ✅ Dictionary + public-key routes | Routes under `chats/:chatId`: `GET/PUT /dictionary`; and `GET/POST /user/public-key` for device key registration (see `user.routes.ts`) | High | Medium |
| 33 | ✅ WS `dictionary-update` ping | After a successful PUT, broadcast a content-free `dictionary-update` (chatId + version) to chat members so open clients re-fetch | Low | Easy |

## Phase 2 — Flutter: crypto core + data layer

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 34 | ✅ Add crypto dependencies | `flutter_secure_storage` (device private key) + `cryptography` (X25519 + AES-GCM) in `pubspec.yaml` | High | Easy |
| 35 | ✅ Dictionary crypto core | `services/dictionary_crypto.dart`: `ensureKeyPair()` (X25519 seed in secure storage), `createChatKey()`, `wrapChatKey()/unwrapChatKey()` (ephemeral X25519 + AES-GCM), `encryptEntries()/decryptEntries()`, pure static `replaceOutgoing()`/`expandIncoming()` (word-boundary token swap) | High | Hard |
| 36 | ✅ Dictionary repository + provider | `repositories/dictionary_repository.dart` (GET/PUT dictionary, GET/POST public key) + per-chat `dictionaryProvider` family: load → unwrap → decrypt → map; lazy-init on first save; Hive cache for offline display | High | Medium |
| 37 | ✅ WS `dictionary-update` event | Parse `dictionary-update` in `models/ws_event.dart`; chat room provider refetches the dictionary when received | Low | Easy |

## Phase 3 — Flutter: UI

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 38 | ✅ DictionaryScreen | AppBar book icon → screen listing code↔meaning entries; add/edit/delete; auto-save (re-encrypt + rebuild wraps); per-member "wrapped / needs re-key" status | High | Medium |
| 39 | ✅ Send-word replacement | Apply `replaceOutgoing` in `ChatRoomController.sendText`/`editMessage` so real words leave as codes | High | Medium |
| 40 | ✅ Tap-to-reveal display | `MessageBubble` renders codes opaque (underlined when hidden); tapping toggles meanings inline via `CodedText` for text + media captions | High | Medium |

## Phase 4 — Tests & verification

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 41 | ✅ Unit tests | Tests for `replaceOutgoing`/`expandIncoming`, dictionary model parsing, entry validation, wrap/unwrap + encrypt/decrypt round trips; `flutter test` green (129 = 115 + 14) | High | Medium |
| 42 | ✅ Verification | Backend `npx tsc --noEmit` (tolerate pre-existing errors, none from new code) + `flutter analyze` clean + curl smoke of dictionary/public-key endpoints | High | Easy |

## Phase 5 — Chat features: delete messages · download images · invite · room details

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 43 | ✅ Delete-for-everyone UI | Long-press own message → "Delete for everyone" → existing WS `delete` (soft delete + broadcast; author-only enforced server-side; no backend change) | High | Easy |
| 44 | ✅ Delete-for-me backend | Add `deletedFor: string[]` to message docs + `markDeletedForUser` (idempotent `arrayUnion`, no broadcast); `getMessages` gains optional `forUserId` and post-filters it from REST `GET /chats/:id/messages` and WS history; new `POST /chats/:chatId/messages/:messageId/delete-for-me` | High | Medium |
| 45 | ✅ Delete-for-me client | Long-press any message → "Delete for me" → POST; optimistic removal with revert + snackbar on failure | High | Medium |
| 46 | ✅ Download images | Add `gal` dependency; "Save image" action in `ImageViewerScreen` + long-press menu on image bubbles: fetch bytes → temp file → `Gal.putImage` → snackbar; iOS needs `NSPhotoLibraryAddUsageDescription`, Android 10+ none | High | Medium |
| 47 | ✅ Room info model + repository | `RoomInfo` model (`models/chat.dart`): parses `GET /chats/:id/info` — `name`, `access`, `canSendMessages`, `createdBy`, `inviteCode`, `myRelation`, `participants` (`RoomParticipant {clerkId, username, profileImageUrl, role}`; roles owner/admin/member/guest); `isAdmin` getter. `ChatsRepository` additions: `getInfo`, `invite(chatId, username)`, `kick(chatId, targetUserId)` → `POST /kick {targettedUserId}` (backend's misspelled field), `rename(chatId, name)`, `updateAccess(chatId, access, {inviteCode})`, `updateCanSendMessage(chatId, policy)` | High | Medium |
| 48 | ✅ Invite screen | `InviteScreen(chatId)`: search via `UserRepository.searchUsers` → results with **Invite** buttons → `invite`; error mapping 404/400/403 → snackbars; stays open for multiple invites; entry from RoomDetails (admin, non-DM) | High | Medium |
| 49 | ✅ RoomDetailsScreen | App-bar `settings_outlined` (gear) icon opens this instead of `MembersScreen` (removed); **hidden for DMs** (mirrors web app). Groups: info block (name, access badge, can-send policy, created-by, your role); **participants list merged with live online dots** (`room.onlineUsers`), role chips, kick (admin, owner-protected, confirm); **admin section: rename dialog (→ `PUT /name`, pops new name back so the AppBar updates), change access dialog (`PUT /access`), can-send-messages toggle (`PUT /canSendMessage`), invite entry**; leave room with confirm (owner transfer note) → `DELETE /leave`; refresh on open + after actions; loading/error/403 states. DMs: minimal other-user card only | High | Hard |
| 50 | ✅ In-room message search | App-bar `search` icon → bottom-sheet `MessageSearchSheet` (mirrors web `MessageSearch`): live case-insensitive filter over loaded messages (text content + media captions), result count + author/date rows, empty state; picking a result closes the sheet and **scrolls to + briefly highlights** the message (`MessageList` listens on a `ValueNotifier` scroll target, estimate-jump + `Scrollable.ensureVisible`, 2s highlight ring) | Medium | Medium |
| 51 | ✅ Chat-list connection banner | Shared `StatusBanner` widget (error-container strip) used by the room and the chat list; `ChatListSocket` extends `ChangeNotifier` tracking `isConnected`/`attempts`/`lastError` (redacted URL), surfaced via `chatListConnectionProvider` — banner shows the failure detail (error + URL) when the last drop errored, generic "reconnecting…" after a clean close, hidden while healthy | Medium | Medium |
| 50 | ✅ Tests & verification | `RoomInfo` parsing + repository tests (mock `ApiClient`); `InviteScreen` + `RoomDetailsScreen` widget tests; `flutter analyze` + `flutter test` green | Medium | Medium |

✅ **Done:** all ten rows above implemented — delete-for-everyone (WS `delete`) and delete-for-me (`deletedFor` + `POST …/delete-for-me`, optimistic with revert), save-image to gallery, `RoomInfo` model + repository (invite/kick/rename/access/send-policy), `InviteScreen`, `RoomDetailsScreen` (admin section, kick, leave, live online dots), in-room message search with scroll-to-highlight, and the shared chat-list connection banner.

## Phase 6 — Role management

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 52 | ✅ Change member roles | Backend `PUT /chats/:chatId/members/:targetUserId/role` (`{role: admin|member}`, owner only, owner/self/direct-chat guards, no-op on no change) + `ChatService.setRole`; posts a system row ("X was made an admin by Y") via `MessageService` + `broadcastToChat`. Flutter: `ChatsRepository.setRole`; `RoomDetailsScreen` owner-only per-member `PopupMenuButton` (Make admin / Remove admin / Kick) with confirm dialog + refresh + snackbar | High | Medium |

## Phase 7 — Voice messages (audio)

Decisions (confirmed): tap-to-record → tap stop to auto-send (with discard); WAV at
22.05 kHz mono on native (Web falls back to `audio/webm` via MediaRecorder — server
treats any `audio/*` the same); Cloudinary `resource_type: "video"` for streamable
playback; audio excluded from the media gallery grid.

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 53 | ✅ Add audio dependencies | `record` (recording) + `audioplayers` (playback) in `pubspec.yaml`; add `RECORD_AUDIO` to `android/app/src/main/AndroidManifest.xml` (Linux/Web need nothing) | High | Easy |
| 54 | ✅ Voice recorder UI | Mic button in the room input bar: tap to start `record()`, while recording show elapsed timer + stop, on stop → `sendFile(name: 'voice-….wav', mime: 'audio/wav', bytes)`; small ✕ to discard without sending; recording state local to the widget (reuses the existing generic `sendFile` path) | High | Medium |
| 55 | ✅ Audio message bubble | Add `case 'audio'` to the `_MessageContent` content-type switch → new `_AudioMessage` StatefulWidget: play/pause button + progress bar + duration from `audioplayers` `onDurationChanged`, tap-to-open URL fallback, `AudioPlayer` disposed on unmount | High | Medium |
| 56 | ✅ Chat-list preview label | `_mediaLabel` in `models/chat.dart`: `'audio' => '🎵 Audio'`; `hasThumbnail` stays image/video-only | Low | Easy |
| 57 | ✅ Tests & verification | Widget test for the audio bubble play/pause rendering (no real audio I/O); `flutter analyze` + `flutter test` green | Medium | Medium |

✅ **Done (2026-08-17):** all five rows above implemented — `record` + `audioplayers` deps, mic recorder UI in the room input bar (WAV 22.05 kHz mono, elapsed timer, ✕ discard, stop-to-send via `sendFile`), `_AudioMessage` bubble with play/pause + progress bar + duration, `🎵 Audio` chat-list label, and an audio-bubble rendering test (no audio I/O). Backend Phase 10 fully implemented too (see `backend/tasks.md`).

## Phase 8 — Room picture + profile pictures in the chat list

Decisions (confirmed): DM rows keep showing the partner's profile picture (already
works). Group rows show the room picture when set, else the initial letter. The
room picture shows in the chat list row + the RoomDetails header, where an admin
can set/change/remove it. Removing = PUT an empty `pictureUrl` (treated as "no
picture"). No new deps — uploads reuse the existing Cloudinary `POST /api/upload`
route via a multipart helper.

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 58 | ✅ `ChatSummary`/`RoomInfo` model fields | Add `pictureUrl` (`String?`) to `ChatSummary` (fromJson + copyWith) and `RoomInfo` (fromJson) in `models/chat.dart` | High | Easy |
| 59 | ✅ Chat-list group avatar | `_ChatAvatar` in `chat_list_screen.dart`: non-DM rows render `NetworkImage(pictureUrl)` when non-empty, else the initial letter; DM path untouched | High | Easy |
| 60 | ✅ Live room-update handling | `chat_list_provider.dart` `ChatListRoomUpdateEvent` → `copyWith(pictureUrl: …)` from `updates['pictureUrl']` | High | Easy |
| 61 | ✅ Multipart upload helper | `core/api_client.dart`: `http.MultipartRequest` `POST /upload` (same auth header/base URL) returning the Cloudinary `url` | High | Medium |
| 62 | ✅ `ChatsRepository.updatePicture` | `PUT /chats/:chatId/picture` with `{ pictureUrl }` (empty string = remove) | High | Easy |
| 63 | ✅ RoomDetails photo display + edit | `room_details_screen.dart`: show the picture in the `_infoBlock` header (non-DM); admin "Change room photo" → `pickImage()` → upload → `updatePicture` → reload info; "Remove photo" action clears it | High | Medium |
| 64 | ✅ Tests & verification | `RoomInfo`/`ChatSummary` pictureUrl parsing tests; `flutter analyze` + `flutter test` green | Medium | Medium |

✅ **Done:** all seven rows above implemented — `pictureUrl` on `ChatSummary`/`RoomInfo`, group-avatar rendering in the chat list, live `room-update` picture handling, the multipart upload helper, `ChatsRepository.updatePicture`, and the RoomDetails photo display/change/remove UI.

## Phase 9 — Markdown rendering in message bubbles

Decisions (confirmed):
- **Scope:** message bubbles only — media captions, reply previews, and
  chat-list previews stay plain text.
- **Markdown renders immediately, no press needed** (changed 2026-08-17 per
  user feedback: bold/heading messages appeared as plain text until tapped in
  dictionary chats). Tap-to-reveal now only expands code-word meanings — the
  codes still show literally inside the formatted text until revealed.
- **Features:** `#` headings, code blocks (triple-backtick fences), `*italic*`,
  `**bold**`, `~~strikethrough~~` (GFM).
- **Dictionary coexistence (reveal-first):** while code words are hidden the
  bubble shows plain text with code words underlined (markdown syntax shown
  literally); after tap-to-reveal, render full markdown with meanings expanded.
- **Bare URLs keep linking** — a shared `wrapBareUrls()` preprocessor wraps
  bare URLs as markdown links, skipping code-fence contents.
- Backend untouched (content stored raw; rendering is client-side).

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 65 | ✅ Add `flutter_markdown` dep | `pubspec.yaml`: `flutter_markdown` (renders to widgets — no HTML/injection risk; GFM extension set gives `~~strikethrough~~`) | High | Easy |
| 66 | ✅ `wrapBareUrls()` util | New shared helper (e.g. `lib/core/markdown_util.dart`): regex-wrap bare URLs as `[url](url)`, skipping content inside code fences so code isn't rewritten | High | Medium |
| 67 | ✅ `MarkdownMessage` widget | Replace the text branch in `_MessageContent` (bubbles only; captions keep `CodedText`): hidden dictionary state → current plain-text underline render; revealed/no-dictionary → `DictionaryCrypto.expandIncoming` then `Markdown` with `md.ExtensionSet.gitHubFlavored` | High | Medium |
| 68 | ✅ Bubble-styled `MarkdownStyleSheet` | Compact heading sizes (≈1.2–1.4× body), code blocks monospace + dark background + horizontal scroll, link taps routed through the existing `_openUrl` | High | Medium |
| 69 | ✅ Tests & verification | Widget tests: heading/bold/italic/strikethrough/code render in a bubble; hidden-vs-revealed dictionary states; bare-URL wrapping (incl. URLs inside fences untouched); `flutter analyze` + `flutter test` green | Medium | Medium |

✅ **Done (2026-08-17):** all five rows implemented — `flutter_markdown ^0.7.7+1`
dep; `lib/core/markdown_util.dart` `wrapBareUrls()` (bare URLs → `[url](url)`,
code fences skipped, existing links not double-wrapped, trailing sentence
punctuation kept outside the link); `MarkdownMessage` widget (uses
`MarkdownBody` — the scrolling `Markdown` variant needs bounded height, which
bubbles lack; GFM default gives strikethrough); reveal-first dictionary rule
(hidden → literal plain text with underlined codes, revealed/no-dict →
`expandIncoming` then markdown); compact style sheet (headings 1.1–1.35× body,
monospace code + surface background, links routed to `_openUrl`); tests — 6
`markdown_util_test.dart` cases + 5 bubble widget tests (heading/bold/italic/
strikethrough, fenced code, bare-URL link rendering via span underline walk,
URLs-in-fences not linked, hidden-vs-revealed dictionary). 251 Flutter tests
green, `flutter analyze` clean. Web client (chat-demo Phase 1) still open.

## Phase 10 — Stacked code words (`+`-joined runs)

Decisions (confirmed):
- **Syntax:** a stack is codes joined by `+`, e.g. `m+h+t` (Mark home
  tomorrow). The separator is **required** — bare `mht` is *not* a stack.
- **Parsing:** each `+`-segment matches the **longest known code first**, so
  `hq` wins over `h`+`q`; unknown segments stay literal (`m+zz` → "Mark zz").
- **`+` is a word boundary** (not a letter) — stacks inside punctuation like
  `(m+h)` already match via the existing boundary regex.
- **Display + auto-encode:** reveal expands a stack to space-joined meanings;
  sending auto-joins consecutive dictionary words into a stack ("Mark home
  tomorrow" → `m+h+t`, replacing today's `m h t`). Non-dictionary words or
  punctuation between words break the run.
- **Backward compatible:** old space-separated codes (`m h t`) keep working
  exactly as today; already-sent messages need no migration.
- Flutter-only — the web client has no dictionary feature, and the backend
  stores dictionary blobs opaquely (never decrypts), so **no backend changes**.

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 70 | ✅ `expandIncoming` stack support | `services/dictionary_crypto.dart`: parse `+`-runs in the text, expand each segment longest-first, join meanings with spaces; runs mixed with plain words and inside punctuation work naturally; reveal-first UI unchanged | High | Medium |
| 71 | ✅ `replaceOutgoing` auto-stacking | Rework to token-stream: maximal consecutive runs of dictionary words join into a `+` stack on send; non-dictionary words and punctuation break runs; case-sensitivity + word boundaries preserved | High | Medium |
| 72 | ✅ Dictionary screen hint | `screens/dictionary_screen.dart`: one-line helper under the entry list — "stack codes with `+`: `m+h` → Mark home" | Low | Easy |
| 73 | ✅ Tests & verification | `test/dictionary_crypto_test.dart`: stack reveal (longest-first, unknown segment, mixed text, punctuation, subset-reveal); auto-stack on send (consecutive runs, run-breaking, punctuation, multi-char codes, backward compat); `flutter analyze` + `flutter test` green | High | Medium |

✅ **Done (2026-08-17):** all four rows implemented — `expandIncoming` expands
`+`-runs (longest-first per segment, space-joined, boundary-aware, reveal
subset works inside stacks), `replaceOutgoing` tokenizes and auto-stacks
consecutive dictionary words (punctuation/non-dict words break runs; phrase
meanings still replace as whole phrases first), the dictionary screen shows
the "stack codes with +" tip, and 14 new tests cover stacks + backward
compat (`m h` still expands). 240 Flutter tests green, `flutter analyze`
clean. Backend untouched (dictionary blobs stay opaque).

## Phase 11 — Mentions (@username + @all) — ✅ Done (2026-08-17)
Decisions (implemented):
- **Syntax:** `@username` and `@all`, whole-word tokens, case-insensitive.
- **Composer:** typing `@` opens a participant picker (from the chat's
  `RoomParticipant`s) filtered by the typed prefix; selecting inserts
  `@username ` at the caret. An "@all" chip (group chats) inserts `@all `.
  Members load lazily on the first `@` keystroke (`GET /chats/:id/info`)
  so opening a room never pays for the fetch.
- **Render:** `@username`/`@all` highlighted (link color) and tappable via
  the markdown link-hijack: mentions are pre-encoded as
  `[@username](#mention:<clerkId>)` links before `MarkdownBody` and taps on
  `#mention:` hrefs open a member bottom sheet instead of the browser.
  `mentionizeMarkdown()` in `markdown_util.dart` (word-boundary matching,
  case-preserving, code fences skipped, `_` escaped in labels).
- **Dictionary interplay:** `@` is punctuation so it never joins a code
  stack — `replaceOutgoing`/`expandIncoming` leave mentions intact.
- **Backend split:** server stores raw text + resolved `mentions`; the
  client renders from text tokens (backend Phase 13).
- **Mentioned-me indicator:** a "mentioned you" chip on others' messages
  that mention me, plus a chat-list `@` badge (unread-mention count from
  the backend's `mentionedCount`).

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Model support | `MentionUser` + `ChatMessage.mentions`/`mentionAll` (fromWs/fromRest/copyWith/toJson) + `mentionsMe()` | High | Easy |
| 2 | ✅ Composer `@` picker | `ChatInputBar`: `@` opens a filtered member strip; tap inserts `@username `; `@all` chip when 2+ other members; members fetched lazily via `getInfo` | High | Medium |
| 3 | ✅ Bubble highlight + tap | `mentionizeMarkdown` → `[@name](#mention:userId)` links; `#mention:` taps open the member sheet; works inside markdown bubbles | High | Medium |
| 4 | ✅ Mentioned-me indicator | "mentioned you" chip on bubbles; chat-list `@N` badge from `ChatSummary.mentionedCount` (REST + `new-message`/`unread-update` events) | High | Medium |
| 5 | ✅ Tests & verification | `test/mentions_test.dart` (20 tests): model parse/round-trip/mentionsMe; mentionize (case, boundaries, fences, @all, underscores); mentionedCount parse + reduceChatList; bubble link render + tap→sheet; chip (mention/@all/own-message); picker insert + @all in group/DM. 275 Flutter tests green, `flutter analyze` clean | High | Medium |

## Phase 12 — Invite links + message forwards + copy — ✅ Done (2026-08-19)
Decisions (implemented):
- **Invite links:** server-generated code (backend Phase 14). `RoomDetailsScreen`
  gets an admin "Invite link" tile → sheet with room name + link, Copy
  (Clipboard), Share (`share_plus`), Generate new / Revoke. New
  `JoinInviteScreen` pastes a code → `getInviteInfo` preview → `joinByCode` →
  open the room; `JoinRoomScreen` gains a "Join with invite link / code" entry.
  Deep links (`https://<host>/join/<code>`, `chat://join/<code>`) are captured
  via `app_links` (`core/deep_link.dart`), parked in `pendingInviteCodeProvider`,
  and consumed by `AuthGate` after sign-in (best-effort; pasteable code is the
  guaranteed path, so no App-Links/Universal-Links platform config for MVP).
- **Forwards:** long-press → "Forward" on real messages → `ForwardToScreen`
  (chat list picker, current chat excluded) → `POST …/messages/:id/forward` →
  snackbar. `ChatMessage.forwardedFrom` parsed + rendered as a "Forwarded from
  …" tag. Verbatim code-word copy (documented limitation).
- **Copy:** long-press → "Copy" — clipboard text via
  `DictionaryCrypto.expandIncoming(…, reveal: all)` when the room has a
  dictionary (copies what you see), else the raw content; media copies caption
  or the media URL. Client-only.

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Model: `ForwardedFrom` + copy helper | `ChatMessage.forwardedFrom` (fromWs/fromRest/copyWith/toJson); `messageCopyText(message, entries)` returns display text / caption / URL | High | Easy |
| 2 | ✅ Repositories | `ChatsRepository.createInviteLink/revokeInviteLink/getInviteInfo/joinByCode`; `MessagesRepository.forward(sourceChatId, messageId, targetChatId)` | High | Easy |
| 3 | ✅ Bubble: Copy + Forward + tag | `message_bubble.dart` action-sheet entries (real messages); "Forwarded from …" tag; `message_list.dart` + `chat_room_screen.dart` wiring | High | Medium |
| 4 | ✅ `ForwardToScreen` | Chat-list picker (shows all chats including current) → pops the target → forward → snackbar | High | Medium |
| 5 | ✅ Invite-link UI | `RoomDetailsScreen` tile + sheet (copy/share/generate/revoke); `JoinInviteScreen` (code → preview → join → open room); `JoinRoomScreen` entry | High | Medium |
| 6 | ✅ Deep link + auth hand-off | `app_links` + `core/deep_link.dart` + `pendingInviteCodeProvider`; `AuthGate` consumes after sign-in; `pubspec.yaml` (+`app_links`, `share_plus`) | Medium | Medium |
| 7 | ✅ Tests & verification | `test/` — `forwardedFrom` parse/round-trip; `messageCopyText` (plain/dict-expanded/media); forward picker + join-by-code widget tests (fake ApiClient). `flutter analyze` + `flutter test` green | High | Medium |

## Phase 13 — Friend request notifications (in-app realtime) — ✅ Done (2026-08-20)

Decisions (confirmed):
- **Channel:** the existing `/ws/chat-list` socket + backend `broadcastToUser`
  (mirrors `new-message`/`invited`); **no FCM/push** for now.
- **Events:** `friend-request` (to the **recipient** when a request is sent) and
  `friend-request-accepted` (to the **original sender** when accepted). No
  decline/cancel notifications.
- **Chat list untouched:** the events are consumed by a dedicated listener, not
  `reduceChatList` (its `default` case leaves the list unchanged).
- Backend side is tracked in `backend/tasks.md` Phase 15 (done 2026-08-20).

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Friend-request ChatList events | `models/ws_event.dart`: `ChatListFriendRequestEvent` + `ChatListFriendRequestAcceptedEvent` (requestId + `from {clerkId, username, profileImageUrl?}`); parsed in `ChatListEvent.fromJson` for `friend-request` / `friend-request-accepted` | High | Easy |
| 2 | ✅ `FriendRequestNotifier` listener | `widgets/friend_notification_listener.dart`: ConsumerStatefulWidget wrapping `HomeShell` in `AuthGate`; `ref.listen` on `chatListEventsProvider` → snackbar "X sent you a friend request" + `ref.invalidate(friendRequestsProvider)`; "X accepted your friend request" + invalidate `friendsProvider` + `friendRequestsProvider` | High | Medium |
| 3 | ✅ Tests & verification | `models_test.dart` parses both events; `chat_list_provider_test.dart` — `reduceChatList` leaves the list unchanged; widget test for the listener (overridden events stream + friends providers → snackbar + Requests refetch). `flutter analyze` + `flutter test` green (309) | High | Medium |

Note: `ChatListFriendRequestAcceptedEvent.from` carries the **acceptor** (the
actor whose action triggered the event), matching `ChatListFriendRequestEvent`
where `from` is the sender — the snackbar always reads "{from} …".

## Phase 14 — Chat UX improvements — ✅ Done (2026-08-20)

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Hide own typing indicator | When the current user is typing in a room, do not show the "you are typing" banner to themselves; only display other users' typing indicators | High | Easy |
| 2 | ✅ DM seen status: "seen" / "not seen" | In direct (1:1) chats, replace the "seen by X" label with a simple "seen" or "not seen" indicator on the last outgoing message; keep the full seen-by list available via the modal (task 3) | High | Easy |
| 3 | ✅ Seen-by modal | Move the seen-by details to a bottom sheet / modal triggered by tapping the "seen" label; prevents message bubbles from being crowded with usernames in group chats; modal lists each reader with avatar + username + read timestamp | High | Medium |
| 4 | ✅ Multi-line message input | Support newlines in the message composer so users can type multi-line messages; the input field should expand vertically up to a reasonable max height, with a scroll for overflow; sending uses the existing WS `message` event (content already stored as-is) | Medium | Medium |
| 5 | ✅ Edit message | Long-press own message → "Edit" → pre-fill the input bar with the current content; on send, dispatch WS `edit` event with the updated text; show an "edited" label on edited messages; restrict editing to the message author only (backend-enforced); handle dictionary re-encoding on edit (apply `replaceOutgoing` to the edited text) | High | Medium |
| 6 | ✅ Copy message | Long-press any message → "Copy" → copy the message text (or media caption / URL) to the clipboard; when a dictionary is active, copy the revealed/expanded text (what the user sees); show a snackbar confirmation ("Copied") | High | Easy |

## Phase 15 — Friend system fixes — ✅ Done (2026-08-20)

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Investigate friend request refresh bug | Friend requests are not refreshing properly — investigate root cause and implement a fix; accepting/declining/canceling a request immediately reflects in the UI without a manual pull-to-refresh | High | Medium |
| 2 | ✅ Remove friend: disable DM chat + system message | Backend (`backend/`, see `backend/tasks.md` Phase 15): `removeFriend` now locks the DM (`canSendMessages: "admins"` → read-only) and posts a system message `"{remover} removed {other} as a friend"` (`event: "friend-removed"`); `acceptFriendRequest` resets the DM policy to `"everyone"`; the DELETE route broadcasts a `friend-removed` ChatList event to the removed user (remover refreshes locally) + a live room frame (with message id) + a room-update (`canSendMessages: admins`) to both users + a chat-list `new-message` preview per participant. Flutter: `ChatListFriendRemovedEvent` model + parsing; `FriendNotificationListener` shows "X removed you as a friend" and invalidates `friendsProvider`; `chat_room_screen` seeds the send policy from `RoomInfo` for DMs too (a fresh-open disabled DM locks input) and passes the DM-specific hint "You can no longer send in this chat" to `ChatInputBar` (new `lockedHint`); `chatListProvider` invalidation added after accept (requests + add-friends) and remove (friends) so the DM appears/updates in the Chats tab | High | Medium |
| 3 | ✅ Tests & verification | Widget tests for: accepted request tile disappears immediately without pull-to-refresh; accepting also refreshes the chat list (DM appears); disabled-chat state (DM locked by friend removal shows the DM hint; open DM stays editable); `ChatListFriendRemovedEvent` parsing (with/without username); friend-removed listener snackbar + friends-only refetch. Backend smoke-requests extended: DM locked after removal, system message present, re-friend resets policy. `flutter analyze` + `flutter test` (317) + backend `tsc --noEmit` + smoke all green | High | Medium |

## Phase 16 — Room descriptions + friends-only invites

Decisions (confirmed):
- **Room descriptions:** RoomDetails only — shown in the info block, editable
  by admins via a dialog. Not set at creation, not shown in join/search
  previews.
- **Friends-only room adds:** enforced on the BACKEND — `POST
  /chats/:chatId/invite` rejects non-friends (403). The invite screen keeps
  global search; the rejection surfaces as an error snackbar. Invite links /
  public join / join-requests are out of scope for this rule.

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Backend: chat `description` field | Add `description` (default `""`) to `ChatDocSchema` (`db/schema.ts`); accept an optional `description` in `POST /chats`; include it in chat summaries (`/chats/all`) and room info (`/chats/:id/info`) responses | High | Easy |
| 2 | ✅ Backend: `PUT /chats/:chatId/description` | Admin-only route (mirrors rename/picture in `chatId.route.ts`): trim + length-cap (≤300 chars), set the field via `ChatService`, broadcast a `room-update` | High | Easy |
| 3 | ✅ Backend: friends-only invite enforcement | `POST /chats/:chatId/invite` — reject with 403 when the target isn't in the inviter's `friends` array (before joining); keeps all existing checks | High | Medium |
| 4 | ✅ Flutter: `RoomInfo.description` + repo | `models/chat.dart` `RoomInfo.fromJson` gains `description`; `ChatsRepository.updateDescription(chatId, description)` → `PUT /chats/:chatId/description` | High | Easy |
| 5 | ✅ Flutter: RoomDetails description UI | Show the description in `_infoBlock`; admin "Edit description" dialog (mirrors the rename dialog); refresh info after save | High | Medium |
| 6 | ✅ Tests & verification | Backend `tsc --noEmit` + `smoke-chats` (description create/update + trim + summary exposure); Flutter: `RoomInfo` description parse + RoomDetails widget tests (display, admin edit PUT + chat-list refresh, non-admin hides tile); `flutter analyze` + `flutter test` (326) green | High | Medium |

## Phase 17 — Dictionary save conflict recovery — ✅ Done (2026-08-20)

Decisions (confirmed): auto-merge + retry. When a dictionary save loses a version
race against another member, the loser refetches the freshest dictionary, merges
their local edits on top (local wins per code, remote-only entries preserved),
re-encrypts, and retries — both members keep their work.

- **Backend:** `DictionaryVersionConflictError` thrown from
  `db/dictionary.store.ts` when `payload.version <= storedVersion` (and on RMW
  retry exhaustion); the PUT `/dictionary` route maps it to **HTTP 409**
  (was 500) so clients can detect the race. `smoke-dictionary.ts` asserts the
  typed error; `e2e-http.ts` asserts a stale-version PUT returns 409.
- **Flutter:** `DictionaryCrypto.mergeDictionaryEntries(remote, local)` (union,
  local priority, remote-only preserved, local order kept);
  `DictionaryController.save` retries up to 3× on a 409 — reloads fresh state,
  merges, re-encrypts with the (re-unwrapped) chat key; bails with a clear
  message on persistent conflicts or if the device lost its key wrap. `_load`
  gained an in-flight guard so WS `dictionary-update` pings and conflict
  reloads can't race. `DictionaryScreen._save` syncs its local list from the
  returned merged set.
- **Tests:** 5 `mergeDictionaryEntries` unit tests, a `DictionaryRepository` 409
  test, 3 `DictionaryController` conflict tests (merge+retry, too-many-conflicts,
  needs-rekey bail), and a `DictionaryScreen` widget test that saves through a
  conflict and shows the merged list. `flutter analyze` clean, 341 Flutter tests
  green, backend `tsc --noEmit` + `smoke-dictionary` green.

## Phase 18 — Mute + block UI (client side of backend Phases 16–18)
Decisions (confirmed):
- Admin mutes use Discord-style durations (8 hours / 1 week / forever).
- Self-mute state is server-side (`mutedByUser` on the membership) so it
  survives reinstalls and push filtering happens before FCM sends.
- Blocking backend/UI-in-DM-details already shipped; this phase surfaces the
  rest (management screen + entry points).

| # | Title | Description | Priority | Difficulty |
|---|-------|-------------|----------|------------|
| 1 | ✅ Mute member UI | `room_details_screen.dart`: "Mute…" action per member → duration sheet (8 hours / 1 week / Forever) + "Unmute"; 🔇 badge + "until …" in participants; system rows render via the existing event pipeline | High | Medium |
| 2 | ✅ Muted-self input state | Disable own input with "You're muted until X" when my `mutedUntil` is in the future (from room info); mirrors the admins-only lock | Medium | Easy |
| 3 | ✅ Self-mute bell toggle | Chat AppBar bell reflecting `mutedByUser` from room info; PUT/DELETE `/chats/:id/mute-me`, optimistic flip + snackbar | High | Easy |
| 4 | ✅ Blocked-users screen | `BlockedUsersScreen`: list via `getBlocked()` + unblock buttons; route from ProfileScreen settings section | High | Easy |
| 5 | ✅ Block entry points | Block action on user-search results and friends-list row menus → confirm dialog → `blockUser()` (mirrors room_details flow) | Medium | Easy |
| 6 | ✅ Tests + analyze | Widget tests: mute action state, self-mute toggle, blocked-list unblock. `dart analyze` clean, full `flutter test` green | High | Medium |

✅ **Done (2026-08-23):** all six rows implemented — admin mute/unmute with Discord-style durations in `RoomDetailsScreen` (PopupMenuButton with Mute…/Unmute/Kick, 🔇 badge, duration sheet); self-mute input state (`canSend: false` + `lockedHint: "You've muted this chat"` when `mutedByUser`); bell toggle in chat AppBar (`notifications_off`/`notifications_active` icons, `_toggleSelfMute` calling `PUT/DELETE /mute-me`); `BlockedUsersScreen` with unblock buttons routed from ProfileScreen; block entry points on friends-list row menus (PopupMenuButton with Block) and DM header (block/unblock button in `RoomDetailsScreen._dmCard`). 359 Flutter tests green, `flutter analyze` clean. Backend Phases 16–18 fully implemented too (see `backend/tasks.md`).
