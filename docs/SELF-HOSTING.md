# Run your own Aria server

This runs the Aria backend in Docker and gives it a public HTTPS address through a
Cloudflare Tunnel. You don't need to open any ports on your router.

To use a Navidrome or other Subsonic server instead, you don't need this page. See
[Connect a server](../README.md#connect-a-server).

## What you need

- **A computer at home that stays on.** It needs [Docker](https://docs.docker.com/get-docker/)
  with Compose, and x86-64 and 64-bit ARM both work. Use a home connection, because
  YouTube heavily scrutinizes data-center IP addresses and may block a rented server.
- **A domain on Cloudflare.** The free plan is enough.
- About 2 GB of disk for the image, plus 5 GB for the song cache.

## Set it up

1. **Create a tunnel.** In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com),
   go to **Networks → Tunnels** and create a Cloudflared tunnel. Copy its token,
   which is the long string in the install command.
2. **Publish a hostname.** In the tunnel's public hostname settings, choose a subdomain
   such as `music.example.com`, and set the service to **HTTP** and `localhost:8000`.
   Use `localhost` exactly, because the backend needs it to rate-limit each client
   separately.
3. **Start the server:**

   ```sh
   git clone https://github.com/evince55/Aria.git
   cd Aria/backend
   ./setup.sh
   docker compose up -d --build
   ```

   `setup.sh` asks for your token, creates an API key and prints it. Save the key
   somewhere private.
4. **Check it from outside your network:**

   ```sh
   curl https://music.example.com/api/health
   ```

   You should get JSON containing `"status":"ok"`.
5. **Connect the app.** In Aria, go to **More → Backend**, choose **Aria** as the server
   type, then enter your URL and API key. Tap **Test Connection**.

## Day to day

Run these from the `backend` folder.

| To do this | Run |
|---|---|
| See if it's running | `docker compose ps` |
| Read the logs | `docker compose logs -f backend` |
| Stop it | `docker compose down` |
| Update the server | `git pull && docker compose pull && docker compose up -d --build` |
| Delete it and its cached songs | `docker compose down -v` |

It starts again by itself after a reboot if Docker starts at boot. yt-dlp updates itself
daily and briefly restarts the backend when a new version arrives.

## Settings

Add these to `backend/.env`, then run `docker compose up -d`.

| Setting | Default | What it does |
|---|---|---|
| `MAX_CACHE_GB` | `5` | Maximum size of the song cache |
| `ARIA_LOCAL_PORT` | `8000` | Port for local checks on this computer |
| `YTDLP_UPDATE_INTERVAL_SECONDS` | `86400` | How often to check for a new yt-dlp |

## Using your own HTTPS instead of a tunnel

Press Return when `setup.sh` asks for a token. The server then listens only on
`127.0.0.1:8000` on that computer, so point your own HTTPS reverse proxy there.
The app won't connect to it over plain HTTP in Release builds.

## Keep it safe

- **Treat the API key like a password.** Anyone with your URL and key can use your server
  and your home connection. To replace the key, change it in `backend/.env` and run
  `docker compose up -d`, then update the app.
- **Know what's public.** `/api/health` and `/api/metrics` need no key, and neither does
  `/api/stream` for someone who knows a cached file's name.
- **Add a rate limit at Cloudflare.** A rule under **Security → WAF** gives you a second
  layer in front of the server's own limits.
- **Check the terms that apply to you.** This includes YouTube's terms and Cloudflare's
  terms for serving media, since downloads to the app pass through the tunnel.

## If something goes wrong

- **The server won't start:** run `docker compose logs backend`. A message about
  `ARIA_API_KEY` means `backend/.env` is missing or the key is too short.
- **The tunnel doesn't connect:** run `docker compose logs cloudflared`, and check the token.
- **`curl` returns 502:** check that the hostname's service is `HTTP` and `localhost:8000`.
- **The app says the key is invalid:** compare it with `ARIA_API_KEY` in `backend/.env`.
- **"Sign in to confirm you're not a bot":** YouTube is refusing this IP address. Waiting
  sometimes helps. If you're on a rented server, move to a home connection.
