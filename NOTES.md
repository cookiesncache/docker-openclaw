# Build notes & verified upstream facts

Reference material for building the image. Facts below were verified against the upstream repo and
docs on 2026-06-28 — re-check before relying on them, as OpenClaw is moving fast.

## Upstream image facts (`ghcr.io/openclaw/openclaw:latest`)

| Aspect | Value |
|---|---|
| Dockerfile `ENTRYPOINT` | `["tini", "-s", "--"]` |
| Dockerfile `CMD` | `["node", "openclaw.mjs", "gateway"]` |
| `WORKDIR` | `/app` |
| Runs as | `node` user, **uid 1000** |
| Config/state home | `$HOME/.openclaw` → as node: `/home/node/.openclaw`; state in `.openclaw/state` |
| Config file | `~/.openclaw/openclaw.json` (overridable via `OPENCLAW_CONFIG_PATH`) |
| Default bind | `127.0.0.1` (loopback) — **must pass `--bind lan`** to be reachable over the network |
| Port | `18789` (gateway). Compose also exposes `18790` bridge, `3978` MS Teams |
| Health endpoints | `/healthz`, `/readyz` (aliases `/health`, `/ready`) |
| compose run command | `node dist/index.js gateway --bind lan --port 18789` |

`openclaw.mjs gateway` and `dist/index.js gateway` are both valid entry forms; the Dockerfile uses
the former, compose the latter.

## The permission issue (the reason for this image)

- Default user is uid 1000; bind mount keeps the **host's** ownership (Docker does not remap it).
- On Unraid, `appdata` is owned `99:100`, so uid 1000 cannot `mkdir /home/node/.openclaw/state` →
  `EACCES` → container exits non-zero with an empty-looking log if detached.
- Upstream workarounds: `chown -R 1000:1000 <hostdir>`, or run `--user root` **and** move mounts to
  `/root/.openclaw` (root's `$HOME`), since the app resolves config from `$HOME`.
- **LSIO fix:** PUID/PGID re-maps the internal user at boot; no chown, no root.

## Env vars worth surfacing in the image

- `PUID`, `PGID`, `UMASK`, `TZ` (LSIO standard)
- `OPENCLAW_GATEWAY_TOKEN` (gateway auth)
- `ANTHROPIC_API_KEY` (and other provider keys as needed)
- `OPENCLAW_CONFIG_PATH`, `OPENCLAW_STATE_DIR`, `OPENCLAW_WORKSPACE_DIR` (pinned in upstream compose)

## Minimal working `openclaw.json` (LAN + token auth)

```json
{"gateway":{"mode":"local","bind":"lan","controlUi":{"allowInsecureAuth":true},"auth":{"mode":"token"}}}
```

`allowInsecureAuth: true` accepts the token over plain HTTP — fine on a trusted LAN / Tailscale
tailnet (where TLS is terminated by `tailscale serve`), **not** for public exposure.

## Open upstream issues to track

- [#41881](https://github.com/openclaw/openclaw/issues/41881) — multi-arch (arm64/armv7) builds.
  Upstream is amd64-only; LSIO publishes arm64, so this affects whether we build from source.
- [#61779](https://github.com/openclaw/openclaw/issues/61779) — gateway binds 127.0.0.1 inside the
  container, blocking Docker port forwarding unless `--bind lan` is set.

## Build-strategy decision (DECIDED 2026-06-28)

**Chosen: hybrid — copy the prebuilt `/app` from the upstream image onto the LSIO base.**

Rationale: upstream builds from source via pnpm into `node:24-bookworm-slim`. Rebuilding that
ourselves (pnpm workspace + `build:docker` + `ui:build`) is high upkeep. Instead:

- `FROM ghcr.io/openclaw/openclaw:latest AS upstream` → `COPY --from=upstream /app /app`.
- Final base `ghcr.io/linuxserver/baseimage-ubuntu:noble` + Node 24 from NodeSource.

Constraints this locks in:

- **amd64-only** — upstream publishes no arm64, and we copy its binaries.
- **glibc base + Node major 24 are mandatory** — the copied `node_modules` contains a native
  state-DB module compiled for Node 24 / Debian glibc. Noble (glibc 2.39 ≥ Bookworm 2.36) is
  forward-compatible. Alpine/musl or a different Node major = crash on module load.
- Tracking upstream = bump the `FROM` tag (ideally pin by digest) and rebuild.

Fallback if the copy ever breaks (native module won't load): rebuild from source on the LSIO base,
or `npm rebuild` the offending module against the local Node.

## LinuxServer compliance (adversarial audit, 2026-06-28)

Audited against live LSIO sources (baseimage-ubuntu noble s6 tree, docker-code-server, docker-jellyfin,
s6-overlay v3). Grade: ~B-/B as a self-hosted LSIO-*style* image (not built for official adoption).
Note: `linuxserver/docker-project-template` is stale (s6 v2), so v3 conventions were anchored to mature
images instead.

Fixed:
- **F1 (HIGH, real defect):** services must gate on the base `init-services` bundle, and app config
  oneshots link into `init-config-end`. Was: `svc-openclaw` depended directly on `init-openclaw-config`
  and never on `init-services` → latent start-order race (breaks under Docker Mods / custom-files).
  Now: `svc-openclaw/dependencies.d/init-services` + `init-config-end/dependencies.d/init-openclaw-config`.
- **F7 (idiom):** seed config moved from an inline heredoc to `root/defaults/openclaw.json` (LSIO
  `/defaults` pattern); the oneshot now `cp`s it.
- **F5:** added `.dockerignore` so `.git`/`.env` never enter the build context.

Correct already (audit-confirmed): `HOME=/config` idiom, PUID/PGID/UMASK/TZ delegation, service naming,
shebangs, `up`→`run` indirection, LF + committed exec bits, no secrets, RUN step-marker style, no
CMD/ENTRYPOINT (s6 `/init` is PID 1).

Deferred (decisions / out of scope):
- **F2/F3:** copy-from-upstream + `:latest` — pin by digest (capture at build time). Copy-from-image is
  an adoption-blocker but a deliberate, documented self-host trade-off.
- **F7 security (RESOLVED):** `allowInsecureAuth` is now gated behind `OPENCLAW_ALLOW_INSECURE_AUTH`
  (default `false` = secure); the config oneshot enforces it into openclaw.json on every boot via node.
- **Adoption-only (not pursued):** Jenkinsfile, jenkins-vars.yml, package_versions.txt, readme-vars.yml,
  Dockerfile.aarch64/arm64, `.github` templates, the LSIO LABEL string, LICENSE.
