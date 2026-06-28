# docker-openclaw

[![build](https://github.com/cookiesncache/docker-openclaw/actions/workflows/build.yml/badge.svg)](https://github.com/cookiesncache/docker-openclaw/actions/workflows/build.yml)

A [LinuxServer.io](https://www.linuxserver.io/)-style Docker image for the
[OpenClaw](https://github.com/openclaw/openclaw) AI assistant gateway.

> ⚠️ **Unofficial.** This is an independent, community-maintained image. It is **not** affiliated with,
> maintained by, or endorsed by OpenClaw **or** LinuxServer.io — it simply follows LinuxServer's
> conventions (`PUID`/`PGID`, s6-overlay, `/config`) and mirrors their GPL-3.0 license.

## Why this image

The official OpenClaw image runs as a fixed `uid 1000` and writes its state under `$HOME`. On hosts
where the mounted config directory isn't owned by `1000` (e.g. Unraid `appdata`, owned `99:100`), it
fails to start with `EACCES: permission denied … mkdir … /state`.

This image adopts the LinuxServer permission model: a fixed internal user is remapped to your
`PUID`/`PGID` at startup and `/config` is chowned automatically — so that error can't happen. Set
`PUID`/`PGID` to match your host and it just works.

- **`PUID`/`PGID`/`UMASK`** ownership handling — no manual `chown`
- **s6-overlay** init and supervision
- Config, state and workspace persist under **`/config`**
- Tracks upstream OpenClaw and is **rebuilt weekly** by CI
- **amd64 only** (upstream publishes no arm64 image — see [Limitations](#limitations))

## Install

### Unraid (Community Applications)

Search Community Applications for **openclaw** and install. Keep `PUID=99` / `PGID=100` so it matches
`appdata` ownership, set a gateway token, and map `/config` to `/mnt/user/appdata/openclaw`.

### docker-compose

```yaml
services:
  openclaw:
    image: ghcr.io/cookiesncache/openclaw:latest
    container_name: openclaw
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - OPENCLAW_GATEWAY_TOKEN=change-me        # openssl rand -hex 24
      - ANTHROPIC_API_KEY=                      # optional
    volumes:
      - ./config:/config
    ports:
      - 18789:18789
    restart: unless-stopped
```

A full `docker-compose.yml` (with the optional provider keys) and an `.env.example` are in this repo.

## Configuration

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PUID` / `PGID` | `911` | User/group ID that owns `/config`. Unraid: `99`/`100`. |
| `UMASK` | `022` | Umask for created files. |
| `TZ` | — | Timezone, e.g. `America/New_York`. |
| `OPENCLAW_GATEWAY_TOKEN` | — | Gateway auth token (**required**). Generate: `openssl rand -hex 24`. |
| `ANTHROPIC_API_KEY` | — | Anthropic API key (optional). |
| `OPENCLAW_ALLOW_INSECURE_AUTH` | `true` | Allow the Control UI to authenticate over plain HTTP — see below. |

Additional optional provider keys / bot tokens are also passed through:
`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, `XAI_API_KEY`, `ZAI_API_KEY`,
`COPILOT_GITHUB_TOKEN`, `DISCORD_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`, `BRAVE_API_KEY`.

### Volumes & ports

| Path / Port | Purpose |
|---|---|
| `/config` | Config, state and workspace (`openclaw.json`, `state/`, `workspace/`). |
| `18789/tcp` | Gateway / Control UI. |

### Accessing the Control UI

The gateway listens on plain HTTP. `OPENCLAW_ALLOW_INSECURE_AUTH` defaults to **`true`**, which is
correct when TLS is terminated **in front** of the container (Tailscale serve, or a reverse proxy):
the edge provides HTTPS and the gateway only sees localhost HTTP.

**Do not expose port `18789` directly to the internet.** Put it behind Tailscale or a reverse proxy.
If you terminate HTTPS at the gateway itself, set `OPENCLAW_ALLOW_INSECURE_AUTH=false`.

## Updating

CI rebuilds and pushes `ghcr.io/cookiesncache/openclaw:latest` weekly (and on every change), tracking
upstream OpenClaw releases. On Unraid, enable **CA Auto Update Applications** to pull new images
automatically.

## Limitations

- **amd64 only.** The image copies OpenClaw's prebuilt application (including a native module) from the
  official image, which is published for amd64 only
  ([openclaw#41881](https://github.com/openclaw/openclaw/issues/41881)).

## Building

```bash
docker build -t ghcr.io/cookiesncache/openclaw:latest .
```

Design decisions, the upstream-image facts, the native-module ABI constraints, and the LinuxServer
compliance notes are documented in [NOTES.md](NOTES.md).

## Support

- Unraid forum thread: <https://forums.unraid.net/topic/199671-support-openclaw-linuxserverio-style-openclaw-gateway-unofficial/>
- GitHub issues: <https://github.com/cookiesncache/docker-openclaw/issues>

## License

The packaging in this repository — Dockerfile, s6 service definitions, and the Unraid template — is
licensed under [GPL-3.0](LICENSE), mirroring LinuxServer.io's licensing.

This image **bundles and redistributes OpenClaw**, which is licensed under the **MIT License**
(© 2026 OpenClaw Foundation). That notice is preserved in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and at `/licenses` inside the image. See
[openclaw/openclaw](https://github.com/openclaw/openclaw) for upstream sources and their own
third-party notices.
