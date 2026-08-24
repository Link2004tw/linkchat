#!/usr/bin/env bash
# Runs the Flutter app on Linux desktop, pulling CLERK_PUBLISHABLE_KEY from
# an .env file so you don't have to type it every time.
#
#   ./run_linux.sh                        # reads backend/.env (or ./env)
#   API_HOST=192.168.1.20 ./run_linux.sh  # override the API host too
#
# Environment variables set on the command line always win.

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
  echo "  flutter run -d linux --dart-define=CLERK_PUBLISHABLE_KEY=pk_test_..." >&2
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

DEFINES=(--dart-define=CLERK_PUBLISHABLE_KEY="$KEY")
# Optional API_HOST override (defaults are platform-aware in config.dart).
if [[ -n "${API_HOST:-}" ]]; then
  DEFINES+=(--dart-define=API_HOST="$API_HOST")
fi

echo "Using $ENV_FILE → flutter run -d linux ${DEFINES[*]}"
exec flutter run -d linux "${DEFINES[@]}"
