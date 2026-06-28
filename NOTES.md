# Maintainer notes

Design decisions and reference facts for this image. Upstream facts were verified against the OpenClaw
repository and docs (last checked 2026-06-28); re-verify before relying on them, as OpenClaw moves fast.

## Upstream image facts (`ghcr.io/openclaw/openclaw:latest`)

| Aspect | Value |
|---|---|
| Final base | `node:24-bookworm-slim` (Debian 12, glibc, amd64) |
| `ENTRYPOINT` / `CMD` | `["tini","-s","--"]` / `["node","openclaw.mjs","gateway"]` |
| `WORKDIR` | `/app` |
| Runs as | `node` user, uid 1000 |
| Config/state home | `$HOME/.openclaw` (state in `.openclaw/state`) |
| Config file | `~/.openclaw/openclaw.json` (overridable via `OPENCLAW_CONFIG_PATH`) |
| Default bind | `127.0.0.1` — `--bind lan` is required to be reachable over the network |
| Port | `18789` (gateway) |
| Health endpoints | `/healthz`, `/readyz` (aliases `/health`, `/ready`) |

## The permission problem this image solves

The official image runs as a fixed uid 1000, and a bind mount keeps the host's ownership (Docker does
not remap it). On Unraid, `appdata` is owned `99:100`, so uid 1000 cannot create
`/home/node/.openclaw/state` → `EACCES`, and the container exits. Upstream workarounds are to `chown`
the host directory to 1000, or to run as root with the mount moved to `/root/.openclaw`. The
LinuxServer model removes the problem: the internal user is remapped to `PUID`/`PGID` at boot and
`/config` is chowned automatically.

## Build strategy

The image copies OpenClaw's prebuilt `/app` from the official image onto the LinuxServer base, rather
than rebuilding from source:

- `FROM ghcr.io/openclaw/openclaw:latest AS upstream` → `COPY --from=upstream /app /app`
- Final base `ghcr.io/linuxserver/baseimage-ubuntu:noble` + Node 24 from NodeSource

Upstream builds from source via pnpm; reproducing that (`pnpm install` + `build:docker` + `ui:build`)
is high-maintenance, so the copy approach is used instead. Consequences:

- **amd64 only** — the copied binaries are amd64; upstream publishes no arm64.
- **glibc base + Node major 24 are mandatory.** The copied `node_modules` contains a native state-DB
  module compiled for Node 24 / Debian glibc. Ubuntu Noble (glibc 2.39 ≥ Bookworm's 2.36) is
  forward-compatible. An Alpine/musl base or a different Node major would crash the module on load.
- Updates track upstream by rebuilding against `:latest` (weekly CI). This trades build reproducibility
  for automatic upstream tracking — a deliberate choice for this image.

**Fallback** if the copied native module ever fails to load: rebuild from source on the base image, or
`npm rebuild` the offending module against the installed Node.

## Auth posture

`openclaw.json` is seeded on first run from `root/defaults/openclaw.json`. The `controlUi.allowInsecureAuth`
field is driven by `OPENCLAW_ALLOW_INSECURE_AUTH` (default `true`) and re-applied on every boot by the
config oneshot, so the variable stays authoritative. Default `true` is correct because the gateway
always serves plain HTTP and relies on a front terminator (Tailscale serve / reverse proxy) for TLS —
it cannot observe the edge TLS, so `false` would reject those proxied connections and only makes sense
if TLS terminates at the gateway process itself (not OpenClaw's model).

## LinuxServer conventions

s6-overlay v3 layout under `root/etc/s6-overlay/s6-rc.d/`:

- `init-openclaw-config` (oneshot) — builds the `/config` tree, seeds `openclaw.json`, applies the auth
  variable, `lsiown`s to the runtime user. Linked into the base `init-config-end` bundle.
- `svc-openclaw` (longrun) — runs `node openclaw.mjs gateway --bind lan --port 18789` as `abc` via
  `s6-setuidgid`. Depends on the base `init-services` bundle (so it starts after all init stages).

`HOME=/config` lands OpenClaw's `$HOME`-relative `~/.openclaw` on the persistent volume. `PUID`/`PGID`/
`UMASK`/`TZ` are delegated to the base image; there is no `CMD`/`ENTRYPOINT` (the base's `/init` is PID 1).

Note: `linuxserver/docker-project-template` is on the legacy s6-overlay v2 layout; the v3 conventions
here follow current mature LinuxServer images (e.g. `docker-code-server`, `docker-jellyfin`) and the
baseimage's own `s6-rc.d` tree.

## Open upstream issues to track

- [openclaw#41881](https://github.com/openclaw/openclaw/issues/41881) — multi-arch (arm64/armv7) builds.
- [openclaw#61779](https://github.com/openclaw/openclaw/issues/61779) — gateway binds 127.0.0.1 inside
  the container, blocking Docker port forwarding unless `--bind lan` is set.
