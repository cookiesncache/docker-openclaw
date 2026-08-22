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
- **Fail-closed defaults** — insecure auth off, allowed-origins control, a seeded auth rate limit,
  and a bind that follows your access method
- **Docker Mods, custom scripts/services, and `FILE__` secrets** — inherited from the LinuxServer base
- Config, state and workspace persist under **`/config`**
- Tracks upstream OpenClaw — CI checks **daily** and rebuilds only when something changed
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
      # Pairing over plain http://<ip>:18789 with no TLS in front? Set this to true.
      # See Access below for the recommended setup instead.
      - OPENCLAW_ALLOW_INSECURE_AUTH=false
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
| `OPENCLAW_ALLOW_INSECURE_AUTH` | `false` | Leave `false`. Set `true` only if you reach the dashboard over plain HTTP with no TLS in front — without it, pairing fails on a plain-HTTP LAN address. |
| `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` | — | Comma-separated allowed origins for the Control UI (CSRF protection). Set to the URL you reach the UI from. |
| `OPENCLAW_GATEWAY_BIND` | — | Advanced. Inbound bind **mode** (`auto`/`loopback`/`lan`/`tailnet`/`custom`), not a host address. Empty → `loopback` when Tailscale Serve is enabled, else `lan`. See [Access](#access). |

Additional optional provider keys / bot tokens are also passed through:
`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, `XAI_API_KEY`, `ZAI_API_KEY`,
`COPILOT_GITHUB_TOKEN`, `DISCORD_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN`, `BRAVE_API_KEY`.

### Volumes & ports

| Path / Port | Purpose |
|---|---|
| `/config` | Config, state and workspace (`openclaw.json`, `state/`, `workspace/`). |
| `18789/tcp` | Gateway / Control UI. |

## Access

The gateway serves **plain HTTP** and does not terminate TLS itself. **Do not expose port `18789`
directly to the internet.** HTTPS comes from a terminator in front — Tailscale Serve or a reverse
proxy — and with one in place the gateway sees the connection as secure, so device pairing works
with `OPENCLAW_ALLOW_INSECURE_AUTH=false`.

### The secure recipe

**Unraid — three toggles**

1. In the container template, enable **Use Tailscale**.
2. Set **Tailscale Serve** to `Serve`.
3. Remove the `18789` port mapping.

Leave `OPENCLAW_ALLOW_INSECURE_AUTH=false` (the default). Reach the UI at
`https://openclaw.<your-tailnet>.ts.net/`.

> **Step 3 is not optional housekeeping.** A published Docker port cannot reach a loopback-bound
> process — the forward DNATs to `eth0`, not `lo`. So once Tailscale is enabled,
> `http://<unraid-ip>:18789` stops working whether or not you remove the mapping. The container
> cannot see host-side port publishing, so it cannot correct this for you; it prints a notice at
> startup instead. If you want the LAN address to keep working alongside Tailscale, set
> `OPENCLAW_GATEWAY_BIND=lan`.

This is Unraid 7.x's own integration — Unraid installs Tailscale into the container and injects the
`TAILSCALE_*` variables. It is **not** a Docker Mod, and nothing in this image provides it. The
container notices `TAILSCALE_SERVE_PORT` and binds loopback automatically; Serve proxies to it from
inside the same container, so nothing needs to listen on the LAN.

**On `br0` / macvlan / ipvlan**, Unraid gives the container its own LAN IP and port mappings are
silently ignored — so `loopback` makes it unreachable from anywhere else, while `lan` publishes it
straight onto your LAN with no host firewall in front. Choose `OPENCLAW_GATEWAY_BIND` deliberately
on those networks rather than relying on the default.

**Plain Docker / compose**

There is no equivalent toggle. Run your own Tailscale sidecar or a reverse proxy, then:

- keep `OPENCLAW_ALLOW_INSECURE_AUTH=false` and open the UI via its `https`/`wss` URL;
- set `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` to that same URL;
- set `OPENCLAW_GATEWAY_BIND` per the next section — a sidecar sharing the container's network
  namespace can use loopback; a proxy on the docker network needs `lan`.

### When you need `OPENCLAW_GATEWAY_BIND=lan`

`bind` controls **inbound** connections only. OpenClaw reaching **out** — to Ollama, to a database,
to any other container — is not affected by it and needs no configuration. People conflate these two
directions constantly; if your problem is OpenClaw failing to *call* something, `bind` is not it.

By default the container picks:

| Condition | Bind |
|---|---|
| `OPENCLAW_GATEWAY_BIND` set to a non-empty value | that value |
| otherwise, `TAILSCALE_SERVE_PORT` present | `loopback` |
| otherwise | `lan` |

`bind` takes a **mode**, not an address: `auto`, `loopback`, `lan`, `tailnet` or `custom`. Legacy
host aliases are normalized for you — `127.0.0.1`, `localhost` and `::1` become `loopback`;
`0.0.0.0` and `::` become `lan` — and the container logs a line when it does so. Anything else is
passed through untouched.

Set `OPENCLAW_GATEWAY_BIND=lan` when something needs to reach **in**:

- a reverse proxy — SWAG, Nginx Proxy Manager, Traefik;
- dashboard widgets — Homepage, Homarr;
- n8n or Home Assistant calling the gateway API;
- most commonly, **another container using the OpenAI-compatible endpoints** the gateway serves on
  the same port: `/v1/models`, `/v1/chat/completions`, `/v1/embeddings`, `/v1/responses`.

Check what the container resolved:

```bash
docker exec openclaw openclaw-resolve-bind
```

### Putting a reverse proxy in front

Setting `lan` for a proxy immediately needs two more things, or the UI will refuse the connection:

1. **`gateway.controlUi.allowedOrigins` must include the proxy's URL.** Set
   `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS=https://openclaw.example.com`.

   OpenClaw auto-seeds loopback origins (`http://localhost:18789`, `http://127.0.0.1:18789`) when
   bound to `lan`, but **applies them at runtime without writing them to `openclaw.json`** — so do
   not be surprised when the file looks empty. Your proxy URL still has to be added explicitly.

2. **`gateway.trustedProxies` must list the proxy's IP**, with `allowRealIpFallback: false`.

And the proxy must **overwrite** `X-Forwarded-For`, not append to it:

```nginx
proxy_set_header X-Forwarded-For $remote_addr;          # correct
# proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;   # WRONG - see below
```

Appending preserves whatever the client sent, so an attacker can prepend a forged address and have
it trusted. Overwriting discards client-supplied values, which is the point.

### First channel you connect: set `commands.ownerAllowFrom`

Do this as part of connecting your first channel (Discord, Telegram, …), not later.

Owner identity in OpenClaw is **channel-scoped** — it is expressed as identities on a specific
channel, so with no channel connected there is nothing for the setting to match and it does
nothing. That makes it easy to skip during setup. The moment a channel *is* connected it becomes
load-bearing: it is what separates "the owner is instructing the bot" from "somebody in the
channel is instructing the bot", and the gateway token does not cover that distinction — the token
guards the HTTP gateway, while messages arrive over the channel.

Set it to your own account on that channel before inviting anyone else, or before joining a
shared server.

## LinuxServer features

Built on the LinuxServer base image, so the standard LinuxServer tooling works out of the box:

- **Docker Mods** — add packages/tweaks at startup without rebuilding:
  `DOCKER_MODS=linuxserver/mods:universal-…` (pipe-separate multiple mods).
- **Custom scripts & services** — executables mounted into `/custom-cont-init.d` run at startup;
  `/custom-services.d` holds long-running services.
- **Secrets from files (`FILE__`)** — keep secrets out of plaintext env by pointing a `FILE__`-prefixed
  variable at a file whose contents become the value (works with Docker secrets):

  ```yaml
  - FILE__OPENCLAW_GATEWAY_TOKEN=/run/secrets/openclaw_token
  - FILE__ANTHROPIC_API_KEY=/run/secrets/anthropic_key
  ```
- **User / group identifiers** — `PUID`/`PGID` set who owns `/config` (find yours with `id youruser`;
  Unraid uses `99`/`100`); `UMASK` controls created-file permissions.

See [LinuxServer's documentation](https://docs.linuxserver.io/) for Docker Mods and container customization.

## Updating

CI checks upstream OpenClaw daily and republishes `ghcr.io/cookiesncache/openclaw:latest` **only when
something that actually goes into the image has changed** — the upstream image, or this repo's
Dockerfile and `root/` tree. A day where nothing moved produces no push, so your install should not
see an update prompt for an image that is byte-identical apart from a build timestamp. On Unraid,
enable **CA Auto Update Applications** to pull new images automatically.

Every published image is boot-tested first — the gateway has to reach `/healthz` and open its state
database before the push happens.

**Tags**

| Tag | Points at | Mutable? |
|---|---|---|
| `:latest` | the newest build | **floats** |
| `:2026.7.1` | the newest build of that upstream release | **floats** |
| `:2026.7.1-1-ls47` | one specific build | never re-pushed — **pin this** |
| `@sha256:…` | exact bytes | immutable |

The `-ls<N>` suffix follows [LinuxServer's convention](https://docs.linuxserver.io/) for "same
upstream version, several image builds", which is exactly this image's situation: upstream ships
`2026.7.1`, `2026.7.1-1` and `2026.7.1-2` as distinct builds of one release, and the monthly rebuild
produces new images at an unchanged upstream version. Both of those would otherwise land on the same
tag.

`:latest` and the bare version tag are convenience pointers and will change under you. **If you need
a fixed artifact, pin the `-ls` tag** — it is published once and never re-pushed.

For byte-exact immutability, pin the digest instead:

```bash
docker buildx imagetools inspect ghcr.io/cookiesncache/openclaw:latest    # prints the digest
# then: ghcr.io/cookiesncache/openclaw@sha256:...
```

Older images carry a short-commit tag (e.g. `:52dca30`). **Do not treat those as pins** — they were
re-pushed on every publish, because most publishes are triggered by upstream moving with no repo
commit at all. They are no longer produced.

**What was this built from?**

```bash
docker inspect -f '{{ index .Config.Labels "io.cookiesncache.openclaw.upstream.ref" }}'   ghcr.io/cookiesncache/openclaw:latest
```

## Limitations

- **amd64 only.** The image copies OpenClaw's prebuilt application (including a native module) from the
  official image, which is published for amd64 only
  ([openclaw#41881](https://github.com/openclaw/openclaw/issues/41881)).

## Building

```bash
docker build -t ghcr.io/cookiesncache/openclaw:latest .
```

That resolves `ghcr.io/openclaw/openclaw:latest` for the application and Node runtime. CI instead
passes a digest and refuses to publish anything unpinned; to reproduce a published image exactly,
pass the same reference its label reports:

```bash
docker build --build-arg UPSTREAM_REF=ghcr.io/openclaw/openclaw@sha256:<digest> .
```

Design decisions, the upstream-image facts, the native-module ABI constraints, and the LinuxServer
compliance notes are documented in [NOTES.md](NOTES.md).

## Support

- Unraid forum thread: <https://forums.unraid.net/topic/199671-support-openclaw-linuxserverio-style-openclaw-gateway-unofficial/>
- GitHub issues: <https://github.com/cookiesncache/docker-openclaw/issues>

Useful diagnostics:

```bash
docker logs -f openclaw                                                   # live logs
docker exec -it openclaw bash                                            # shell into the container
docker inspect -f '{{ index .Config.Labels "build_version" }}' openclaw  # image build version
docker exec -it openclaw node /app/openclaw.mjs --version                # OpenClaw version
docker exec -it openclaw openclaw-resolve-bind                           # resolved inbound bind
docker inspect -f '{{ index .Config.Labels "io.cookiesncache.openclaw.upstream.ref" }}' openclaw
```

## License

The packaging in this repository — Dockerfile, s6 service definitions, and the Unraid template — is
licensed under [GPL-3.0](LICENSE), mirroring LinuxServer.io's licensing.

This image **bundles and redistributes OpenClaw**, which is licensed under the **MIT License**
(© 2026 OpenClaw Foundation). That notice is preserved in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and at `/licenses` inside the image. See
[openclaw/openclaw](https://github.com/openclaw/openclaw) for upstream sources and their own
third-party notices.
