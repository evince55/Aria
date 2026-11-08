# Aria

A free, open-source iPhone music player for your own files and your own server.
Aria works fully offline with no account and no server.

## Features

- **Local library:** import FLAC, ALAC, MP3, AAC, AIFF and WAV files from the Files app.
- **Equalizer:** 10-band parametric EQ, with presets and AutoEQ headphone profiles.
- **Playlists:** smart playlists, M3U import and export, and bulk folder import.
- **Your own server:** connect to Navidrome, another Subsonic server, or the Aria server.
- **Offline downloads:** save tracks from the Aria server to your phone.
- **Ask Your Library:** search your library in plain language (needs the Aria server).
- **Free:** every feature is included, with no purchases or subscription.

## Install

Aria isn't on the App Store yet, so for now you build it yourself. You need:

- A Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) 26.5 or later
- An Apple ID, added in Xcode under **Settings → Accounts** (a free one works)
- An iPhone on iOS 16.6 or later

Then plug in and unlock your phone, and run:

```sh
git clone https://github.com/evince55/Aria.git
cd Aria
make doctor    # tells you if anything is missing
make install
```

To try it in the simulator instead, with no Apple ID or phone, run `make sim`.

> **With a free Apple ID, the app stops opening after 7 days.** Plug in and run
> `make install` again to renew it. Your music and settings are kept. A paid Apple
> Developer account extends this to a year.

## Add your music

Open **Library**, tap **Import** and choose your files. No server is needed.

## Connect a server

Go to **More → Backend** and choose a server type:

| Server | Enter | Notes |
|---|---|---|
| **Subsonic** (Navidrome, Airsonic, Gonic) | URL, username, password | Offline downloads aren't supported yet |
| **Aria** | URL, API key | [Run your own](docs/SELF-HOSTING.md) |

**Use an `https://` address.** Builds from `make install` may refuse plain `http://`.
To reach a private server, such as one on Tailscale, your phone must also be on that
private network, and the address still needs HTTPS.

## Run your own Aria server

The Aria server uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) to search and stream
audio from YouTube, and it powers Ask Your Library. On a computer at home with Docker:

```sh
git clone https://github.com/evince55/Aria.git
cd Aria/backend
./setup.sh
docker compose up -d --build
```

Run it on a home connection, because YouTube may block rented servers. You also need
a domain on Cloudflare for HTTPS, and you're responsible for following the terms of
any service you use it with. The [self-hosting guide](docs/SELF-HOSTING.md) covers
each step.

## Develop

Run the tests with `make test` and `python3 -m pytest backend/tests`. See
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture and setup, and
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for releases.

## License

[MIT](LICENSE)
