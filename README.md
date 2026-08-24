# chat_app

A new Flutter project.

## Running the app

The backend is exposed through ngrok at the default public URL
(`https://flirtatiously-chalcolithic-bria.ngrok-free.dev`). Native targets
(Android, iOS, Linux desktop) talk to it directly — their requests carry a
non-browser User-Agent, which bypasses ngrok's free-plan browser-warning
splash page.

- **Linux desktop**: `./run_linux.sh`
- **Web (Chrome)**: `./run_web.sh` — browser traffic cannot use the ngrok
  domain (ngrok's interstitial blocks browser requests/WebSockets on the free
  plan), so it goes through an SSH tunnel to the backend instead:

  ```sh
  ssh -N -L 3001:localhost:3001 link@fastify-server.local
  ./run_web.sh
  ```

  `run_web.sh` defaults `API_HOST` to `http://localhost:3001` and verifies the
  tunnel is up before launching. Override with `API_HOST=http://host:port`
  when the backend runs elsewhere.

Both scripts pull `CLERK_PUBLISHABLE_KEY` from `./env`, `../backend/.env`, or
`~/.chat_app.env`.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
