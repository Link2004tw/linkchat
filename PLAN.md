# Flutter Chat App — Plan

A Flutter client for the existing Fastify chat backend (`backend/`), sibling to the Next.js web app (`chat-demo/`).

**Stack:** Flutter (Android first) · Riverpod · official Clerk Flutter SDK · `web_socket_channel` · `http`

---

## The API contract this app plugs into

### Auth
- REST calls: `Authorization: Bearer <JWT>` header
- WebSocket calls: `?token=<JWT>` query param (both WS endpoints verify it)

### REST (`http://<host>:3001/api`)
| Area | Endpoints |
|---|---|
| Chat list | `GET /chats`, `GET /chats/all` (last message + unread counts), `GET /chats/search?q=` |
| Groups | `POST /chats` (create), `POST /chats/:id/join`, `POST /chats/:id/join-request`, `GET /chats/:id/requests`, `PUT /chats/:id/requests/:requestId` |
| DMs | `POST /chats/dm/start` (friends only), `GET /chats/dm/conversations` |
| Room admin | `PUT /chats/:id/name`, `/access`, `/canSendMessage`, `POST .../invite`, `POST .../kick`, `DELETE .../leave` |
| Messages | `GET /chats/:id/messages?limit&before` (paginated), `POST /chats/:id/messages`, PATCH/DELETE `.../messages/:messageId` |
| Friends & DMs | `GET /user/friends` (list incl. `dmChatId` per friend), `GET /user/friends/count`, `POST /user/friends` (send req), `GET /user/friends/requests` (in+out), `PUT /user/friends/requests/:id/accept` / `/decline`, `DELETE /user/friends/requests/:id` (cancel), `DELETE /user/friends/:clerkId` (remove), `GET /user/search?q=` (global, w/ `friendRequestStatus`), `GET /user/:clerkId` (profile + `dmId`) |
| Push | `POST /user/push-token` (register FCM token) — backend sends FCM notifications on new messages (task 28) |

### WebSockets
- `ws://host:3001/ws/chat?chatId=X&token=JWT`
  - On connect: last 50 messages + presence snapshot + welcome/system
  - Inbound: `message`, `edit`, `delete`, `typing`, `presence`, `join`, `leave`, `kick`, `invite`, `room-update`, `file-progress`, `file-complete`
  - Outbound: `message`, `edit`, `delete`, `typing`, `file-start` + binary chunks
- `ws://host:3001/ws/chat-list?token=JWT`
  - Inbound: `new-message`, `unread-update`, `room-update`, `invited`, `kicked`, `join-request`
  - Outbound: `mark-read`

### Media
- Files are sent over the chat WS: `file-start` (name, size, mime, replyTo, caption) → binary chunk(s) → server replies `file-progress` → `file-complete` (messageId + Cloudinary url). Cap ~6 MB like the web app.
- Note: `backend/routes/upload.ts` (`POST /api/upload`) is **not registered** in `server.ts` — the WS path is the way to go, no backend change needed.

---

## Phase 0 — Pre-flight
1. **Clerk dashboard**: enable the native/mobile platform on the Clerk instance (Applications → enable **Native**), add the Android package name, grab the **publishable key**.
2. **Reachability** (backend already binds `0.0.0.0:3001`):
   - Android emulator → `http://10.0.2.2:3001` (host loopback)
   - Real device → `http://<LAN-IP>:3001`
   - Configure via `--dart-define=API_HOST=...`.
3. **Android manifest**: `INTERNET` permission + `usesCleartextTraffic="true"` (dev only).

## Phase 1 — Scaffold
- `flutter create` in `flutter-app/`
- Packages: `clerk_flutter`, `flutter_riverpod`, `web_socket_channel`, `http`, `cached_network_image`, `image_picker` / `file_picker`, `intl`
- Structure:
```
lib/
├── main.dart
├── core/
│   ├── config.dart        # API_HOST per platform
│   ├── api_client.dart    # REST + Bearer token
│   └── ws_client.dart     # chat + chat-list sockets
├── models/                # Chat, Message, User (JSON→Dart)
├── providers/
│   ├── auth_provider.dart
│   ├── chat_list_provider.dart
│   └── chat_provider.dart # per-room: messages, pagination, WS
├── screens/               # auth, chat list, chat room, create/join
└── widgets/               # bubbles, typing indicator, presence avatar
```

## Phase 2 — Auth
- Wrap app in Clerk auth; after sign-in `session.getToken()` yields the JWT the backend expects.
- Store token in a Riverpod provider → feeds `api_client` (Bearer) and `ws_client` (`?token=`).

## Phase 3 — Core chat
- Models + REST: chat list (`GET /chats/all`), create group, DM start, join room.
- Chat WS per room: on connect the server pushes last 50 messages + presence + system events; handle inbound types; send `message` / `edit` / `delete` / `typing`.
- Chat-list WS: live `new-message` + `unread-update`; send `mark-read` on room open.
- Pagination: `GET /chats/:id/messages?before=<cursor>` on scroll up.
- Screens: chat list (avatar, last message, unread badge) → room (bubbles, typing indicator, online members) → create room / search & join.

## Phase 3.5 — Friends & DMs
- Friends list screen: `GET /user/friends` → avatar, name, tap-to-open DM via the returned `dmChatId`.
- Add friends: global search `GET /user/search?q=` (shows `friendRequestStatus`: friends / pending / respond / none) + `POST /user/friends` to send.
- Requests: `GET /user/friends/requests` (ingoing + outgoing) → `PUT .../accept` / `PUT .../decline` / `DELETE .../requests/:id` to cancel own.
- Optional: remove friend `DELETE /user/friends/:clerkId`.
- No backend changes needed — everything is REST, already exercised by the web app.

## Phase 4 — Media sharing
- Pick image/file → bytes → WS file protocol (`file-start` → chunks → `file-progress` bar → `file-complete`).
- Render images inline (`cached_network_image`); files as tap-to-open cards; captions supported.

## Phase 5 — Presence + typing
- Presence comes free from the chat WS → online dots on avatars, live member count in room header.
- Typing: debounced sends, "X is typing…" banner.

## Phase 6 — Hardening (post-MVP)
- WS auto-reconnect with backoff + token refresh on reconnect.
- Pull-to-refresh, error/empty states, optimistic sends with retry.
- Optional later: ~~local cache~~ ✅ done, ~~push notifications~~ ✅ done (see below).

---

## Backend review — findings for the Flutter app

### Blocker: send messages only over WS
`POST /api/chats/:id/messages` returns the message **encrypted** (text is stored AES-256-GCM with `iv`/`authTag`; `createMessage` returns the raw doc) and **never broadcasts over WS** — other clients won't see it live. The web app sends exclusively over WS, and so must the Flutter app. WS history/broadcasts are decrypted server-side, so the app needs no crypto.

### Resolved: DMs require friendship → friends added to MVP (Option A)
`POST /api/chats/dm/start` → 403 unless both users are friends. Decision: **the friends system is now in MVP scope**, so DMs work as designed with no backend changes. Bonus: `GET /api/user/friends` returns a `dmChatId` per friend (DM chats are auto-created), so the app opens DMs straight from the friends list; `dm/start` remains the fallback (e.g. from a user profile).

### Blocker: bootstrap the user via `/chats/all`, not `/auth/me`
`GET /api/auth/me` reads nonstandard Clerk session claims (`userid`, `image`), which creates a user with `userId: undefined`. The web app never calls it. Call `GET /api/chats/all` right after sign-in — it runs `getOrCreateUserById`, which creates the local user properly. (`GET /api/user/:clerkId` 404s until the local user exists.)

### Dead code: `POST /api/upload`
`routes/upload.ts` is never registered and `@fastify/multipart` is never registered — the endpoint is non-functional. Fine: the WS file path is the upload path.

### Model quirks the Dart models must tolerate
- Avatar field name differs per endpoint: `profileImageUrl` (WS, `/chats/all`) vs `imageUrl` (`/user/search`, `/user/:clerkId`, DM `otherUser`). Read both.
- Timestamps: WS sends epoch ms numbers; REST returns ISO strings (`getMessages` JSON-serializes). One normalize helper.
- `replyTo`: WS history sends a string id; the create broadcast may send a populated object whose content is ciphertext (backend never decrypts reply previews). Treat as string-or-object, never render reply content from WS.
- `/chats/all` lastMessage.`senderId` is actually the sender's **username** (misnamed).
- System events (`join`/`leave`/`kick`/`invite`/`room-update`) arrive as their own WS types carrying `text` (not `content`).
- `/chats/all` group vs DM shapes differ (`previewMembers` vs `otherUser`) — model as a union.
- WS history is fixed at 50 with no cursor; compute the `before` cursor from the oldest history `messageId`.
- WS file broadcast omits `fileSize`/`isEdited` that history includes — keep nullable.

### Recommended backend changes
- ✅ DONE — Cap WS upload size server-side (10 MB): `MAX_FILE_SIZE` in `plugins/websocket.ts`, rejected at `file-start` with a clear error, plus an overflow guard refusing to buffer more bytes than declared. Also fixed the parsed-message type annotation (`name`/`size`/`mime`) so the block typechecks.
- ✅ DONE — Removed the request logging in `plugins/clerk.ts` that leaked the whole request object + headers (incl. `Authorization: Bearer`) into server logs.
- Optionally send `hasMore`/`nextCursor` in the WS history payload; register `/api/upload` + multipart if REST uploads are ever wanted.

### Fine as-is
- CORS is irrelevant for native mobile (no browser origin).
- Rate limit keys WS handshakes by IP (`req.auth` unset there) — OK for MVP.
- WS token in query string lands in server logs; tokens are short-lived Clerk JWTs — acceptable for MVP.

## Phase 7 — Push notifications (task 28, needs your Firebase setup)

**Backend — implemented.** `POST /api/user/push-token` stores the caller's FCM token (`User.deviceToken`). `services/push.service.ts` lazily initializes `firebase-admin` (from `FIREBASE_SERVICE_ACCOUNT`, a path to a service-account JSON file) and sends a notification to the other chat participants on every WS message (text + media). It is a **silent no-op without the env var** — the backend runs unchanged until you add it.

**Flutter — nearly wired.** `firebase_core` + `firebase_messaging` are **already in pubspec** (the build is verified with them). `lib/services/push_wiring.dart` is the 5-minute enablement file with exact `[PUSH]` markers; `main.dart` already has the app-global `navigatorKey` (needed for tap-to-open) and calls the no-op `initializeFirebaseIfAvailable()`. Until Firebase is configured the app runs exactly as before.

**To enable (each step is a real account/credential action):**
1. **Firebase console** (console.firebase.google.com) → **Add project** → name it. Analytics optional.
2. From `flutter-app/`: `dart pub global activate flutterfire_cli` (one-time), then `flutterfire configure` — pick the project, select **Android**, and the CLI registers the app (package `com.example.chat_app`), writes `lib/firebase_options.dart`, and wires the google-services Gradle plugin automatically. (iOS: add an app + APNs key later, if ever.)
3. Follow the `[PUSH]` markers in `lib/services/push_wiring.dart`: initialize Firebase in `initializeFirebaseIfAvailable()`, replace `PushController.init()` with the full wiring from `lib/services/push_notifications.dart`, and call init/dispose from `AuthGate` (markers are already there).
4. Backend: console → project ⚙️ → **Service accounts** → **Generate new private key** → save the JSON → set `FIREBASE_SERVICE_ACCOUNT=/path/to/that.json` in `backend/.env`.
5. Test on a physical device (an emulator with a Google Play image also works; plain AVDs don't receive FCM).

## Decisions locked in
- **Platform:** Android first
- **MVP scope:** Core chat · Media sharing · Presence + typing · **Friends & DMs** (Option A — backend friend-gating kept as-is)
- **State:** Riverpod
- **Auth:** Official Clerk Flutter SDK

## Status (all 28 tasks complete)
- ✅ Flutter SDK verified, project scaffolded, deps pruned (`cupertino_icons`, `@fastify/env`, `@fastify/helmet`, `fastify-swagger`, `@clerk/backend`, `uuid` removed).
- ✅ Everything builds: `flutter analyze` clean, 115 tests pass.
- ✅ Push (task 28): backend implemented (register + send, safe no-op without `FIREBASE_SERVICE_ACCOUNT`); Flutter client written but disabled until Firebase config exists — see **Phase 7**.

## Open items / risks
- Clerk instance must allow native apps and include the Android package `com.example.chat_app`, otherwise sign-in will fail (one-time dashboard change).
- Android SDK licenses are still unaccepted on the dev machine — `flutter doctor --android-licenses` before the first device run.
- Cleartext HTTP config is dev-only; production needs HTTPS (or a tunnel) because the WS URL scheme follows the page/protocol.
- Run commands and Firebase setup are documented in `RUN.md` at the repo root.
