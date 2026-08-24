#!/usr/bin/env bash
# Runs the Flutter app in Chrome (web), pulling CLERK_PUBLISHABLE_KEY from an
# .env file so you don't have to type it every time.
#
# Browser builds talk to the backend at http://localhost:3001 (NOT the ngrok
# domain): ngrok's free plan shows its browser-warning splash page
# (ERR_NGROK_6024) for every browser request and WebSocket upgrade, so browser
# traffic must reach the backend directly. Start the tunnel first:
#
#   ssh -N -L 3001:localhost:3001 link@fastify-server.local
#
#   ./run_web.sh                                  # tunnel at localhost:3001
#   API_HOST=http://192.168.1.20:3001 ./run_web.sh  # override the API host too
#
# Native targets (Android/iOS/Linux desktop) do NOT need this — their requests
# carry a non-browser User-Agent, which bypasses ngrok's splash page, so they
# keep using the default public ngrok URL.

set -euo pipefail

cd "$(dirname "$0")"

# Find an .env: look for ./env, then ../backend/.env (the backend's env has
# the same Clerk publishable key), then ~/.chat_app.env.
ENV_FILE=""
for candidate in ./env ../backend/.env ~/.chat_app.env; do
  if [[ -f "$candidate" ]]; then
    ENV_FILE="$candidate"
    break
  fi
done

if [[ -z "$ENV_FILE" ]]; then
  echo "error: no .env found (tried ./env, ../backend/.env, ~/.chat_app.env)." >&2
  echo "Add CLERK_PUBLISHABLE_KEY to one of those, or pass it inline:" >&2
  echo "  flutter run -d chrome --dart-define=CLERK_PUBLISHABLE_KEY=pk_test_..." >&2
  exit 1
fi

# Pick the key from the .env (line can be KEY=value or KEY="value"; strip
# quotes and a trailing CR from Windows-style line endings).
KEY=""
while IFS='=' read -r name value; do
  if [[ "$name" == "CLERK_PUBLISHABLE_KEY" ]]; then
    KEY="${value//\"/}"
    KEY="${KEY%$'\r'}"
    break
  fi
done < <(grep -E "^CLERK_PUBLISHABLE_KEY=" "$ENV_FILE")

if [[ -z "$KEY" ]]; then
  echo "error: CLERK_PUBLISHABLE_KEY not found in $ENV_FILE" >&2
  exit 1
fi

# Browser API host defaults to the SSH-tunneled backend. Override with
# API_HOST=http://host:port if you run the backend elsewhere.
API_HOST="${API_HOST:-http://localhost:3001}"

# The tunnel must be up before the app can reach the backend.
if ! curl -sS -o /dev/null --max-time 3 "$API_HOST/api/clerk/v1/health" \
  -H "ngrok-skip-browser-warning: true"; then
  echo "error: $API_HOST is not reachable." >&2
  echo "Start the SSH tunnel first, or set API_HOST to your backend:" >&2
  echo "  ssh -N -L 3001:localhost:3001 link@fastify-server.local" >&2
  exit 1
fi

echo "Using $ENV_FILE → flutter run -d chrome (API_HOST=$API_HOST)"
exec flutter run -d chrome \
  --dart-define=CLERK_PUBLISHABLE_KEY="$KEY" \
  --dart-define=API_HOST="$API_HOST"