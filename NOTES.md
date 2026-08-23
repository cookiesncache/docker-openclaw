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
| Default bind | `loopback` mode — a non-loopback `--bind` is required to be reachable over the network |
| `bind` values | modes, not addresses: `auto`, `loopback` (default), `lan`, `tailnet`, `custom`. Host aliases (`0.0.0.0`, `127.0.0.1`, `localhost`, `::`, `::1`) are documented as unsupported there. |
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

- `FROM ${UPSTREAM_REF} AS upstream` → `COPY --from=upstream /app /app`, where `UPSTREAM_REF`
  defaults to the floating tag for local builds and is always a **digest** in CI
- Final base `ghcr.io/linuxserver/baseimage-ubuntu:noble`, **pinned by digest** (Dependabot bumps it)
- Node 24 **copied from the upstream stage**, not installed from NodeSource

Upstream builds from source via pnpm; reproducing that (`pnpm install` + `build:docker` + `ui:build`)
is high-maintenance, so the copy approach is used instead. Consequences:

- **amd64 only.** Not because upstream lacks arm64 — as of 2026-08 its `:latest` index carries a
  `linux/arm64` manifest alongside amd64. The blocker is this image's build strategy: a single
  `FROM ${UPSTREAM_REF} AS upstream` stage supplies both `/app` and the Node binary, and `COPY
  --from` takes whatever architecture that stage resolved to. Multi-arch would need per-arch
  upstream stages selected by `TARGETARCH`, plus a multi-platform build and a smoke test that can
  boot an arm64 image. Tracked separately; out of scope while the image is amd64-only by design.
- **glibc base + Node major 24 are mandatory.** The copied `node_modules` contains a native state-DB
  module compiled for Node 24 / Debian glibc. Ubuntu Noble (glibc 2.39 ≥ Bookworm's 2.36) is
  forward-compatible. An Alpine/musl base or a different Node major would crash the module on load.
- Updates track upstream by resolving `:latest` to a digest daily in CI and rebuilding only when it
  moves. The build is pinned to that digest and records it as both an image label
  (`io.cookiesncache.openclaw.upstream.ref`) and an index annotation, so any published image can be
  traced to the exact artifact it came from. CI refuses to publish an unpinned reference.

### Why Node is copied instead of installed

The NodeSource route (`curl https://deb.nodesource.com/setup_24.x | bash -` then an unpinned
`apt-get install nodejs`) executed a third party's script as root at build time and pinned nothing.
Copying `/usr/local/bin/node` + `/usr/local/lib/node_modules` from the upstream stage removes that
and is *more* ABI-correct: it is the exact Node build the bundled native modules were compiled
against, rather than whatever NodeSource's 24.x head is that morning.

Verified before adopting it (Node 24.16.0 on the noble base):

- `ldd node` needs only `libdl libstdc++ libm libgcc_s libpthread libc` — all present on noble.
- glibc: bookworm 2.36 → noble 2.39, the forward-compatible direction.
- OpenSSL 3.5.6 is statically linked, so the base's `libssl` is irrelevant.
- Global `fetch` works, so the `HEALTHCHECK` is unaffected.
- Full gateway boot reaches `ready` and `/healthz` returns 200; `/config/.openclaw/state/openclaw.sqlite`
  plus its `-wal`/`-shm` appear, which is the proof the **native state-DB module actually loaded** —
  `openclaw.mjs --version` does not exercise it, so it is not sufficient evidence on its own.

CI re-runs that boot test on every publish, including the scheduled upstream-tracking build, because
this strategy couples us to upstream's internal `/usr/local` layout and Node major. If upstream ever
switches base image, the smoke test fails before anything is pushed.

**Deliberately not pinned: `@openclaw/brave-plugin`.** It installs at runtime into
`/config/.openclaw/npm`, which is a persistent volume, so container rebuilds never reinstall it — the
spec is only re-resolved when `openclaw plugins update brave` is run explicitly. A pin would protect
that single moment while requiring perpetual manual bumps, and a stale pin leaves OpenClaw's doctor
"version drift" warning permanently red, which trains you to ignore doctor output generally. The
replacement control is a publish-date check before running an update:

```bash
npm view @openclaw/brave-plugin@latest version time
```

## The publish gate

CI publishes only when a build input moved. The previous state is stored as an **OCI annotation on
the published index** (`io.cookiesncache.inputs`) and read back with `imagetools inspect --raw` — one
registry read, no external state, and it cannot drift from reality because it *is* what shipped.

Alternatives rejected: the Actions cache (evicted after 7 days idle, and written even if the push
later fails), a committed file (needs `contents: write` in the job holding the GHCR credential, plus
a bot-commit loop), and a repo variable (external state, extra credentials, less accuracy).

The fingerprint hashes the upstream digest together with the **content** of the build inputs
(`git rev-parse HEAD:Dockerfile HEAD:root HEAD:.dockerignore`), not `$GITHUB_SHA`. Using the branch
head would make every documentation commit trigger a republish on the next scheduled run — an image
differing only in `BUILD_DATE`, which every Unraid install would see as a phantom update.

Its one real limitation: deleting the GHCR package version loses the marker and the next run
republishes. That is the correct failure mode — no published image means nothing to compare against.

**Fallback** if the copied native module ever fails to load: rebuild from source on the base image, or
`npm rebuild` the offending module against the installed Node.

### Scheduled-workflow expiry (accepted risk, no machinery)

GitHub disables scheduled workflows after **60 days without repository activity**. A stable repo
with no commits for two months would silently stop tracking upstream — the exact failure the daily
cadence exists to prevent.

Deliberately not defended with a keepalive commit or an external pinger. Two weekly Dependabot
schedules (`github-actions`, `docker`) plus auto-merge for the docker ecosystem mean this repo
realistically never idles 60 days, and Dependabot merges *are* repository activity. A keepalive
would need `contents: write`, add bot-commit noise, and require the fingerprint gate to ignore the
touched path or it would trigger phantom rebuilds; an external pinger adds a credential held
outside GitHub. Neither cost is worth paying for a risk this shape.

**The signal to watch:** the daily `build` run disappearing from the Actions tab. If Dependabot
activity ever stops too (upstream actions all archived, base image frozen), revisit this.

## Tagging

Published on every publish: `:latest`, the bare upstream version (`:2026.7.1`), and an immutable
build tag (`:2026.7.1-1-ls<run_number>`). The first two float; the third is never re-pushed and is
what the README tells people to pin.

Two independent things force a build tag, and neither is expressible as a floating version tag:

- Upstream ships several builds of one release - `2026.7.1`, `2026.7.1-1`, `2026.7.1-2` are three
  distinct digests. Only the OCI label carries that suffix; `openclaw --version` and `package.json`
  both report the bare version, so the label is probed **first**.
- The monthly forced rebuild produces a new image at an unchanged upstream version, forever.

`-ls<N>` is LinuxServer's answer to exactly this (compare `linuxserver/code-server:4.133.0-ls358`),
which suits an image that follows their conventions everywhere else. `github.run_number` supplies the
counter; it is monotonic per workflow, and gaps are expected because runs that publish nothing still
consume a number.

**Do not tag by repo commit.** The old `:<short-sha>` tag was removed because it was actively
misleading: the dominant publish trigger is upstream moving with `HEAD` unchanged, so the same commit
tag was re-pushed over different content on every scheduled publish. Live proof before removal - the
tag `:52dca30` (commit dated 2026-06-29) served an image built 2026-08-17 containing a later upstream
release. The commit is still recorded, as the `org.opencontainers.image.revision` annotation.

The only byte-exact reference is the index digest, which needs no tag scheme at all.

## Auth posture

`openclaw.json` is seeded on first run from `root/defaults/openclaw.json`. The config oneshot then
applies security-relevant settings on every boot:

- `controlUi.allowInsecureAuth` ← `OPENCLAW_ALLOW_INSECURE_AUTH`, **authoritative only when the
  variable is set**. When it is unset the persisted value is left alone; new installs get `false`
  from `root/defaults/openclaw.json`. This is deliberate: the oneshot runs on every boot, so a plain
  `??` fallback would have overwritten the config of every existing install that never set the
  variable — including everyone who copied the README's minimal compose block, which does not set it.
  Unraid and `docker-compose.yml` users materialize the variable explicitly and are unaffected either
  way. OpenClaw's own startup check flags `true` as a dangerous flag.
- `controlUi.allowedOrigins` ← `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` (comma-separated; unset by
  default). Set to the URL the UI is reached from, for CSRF/origin protection on a non-loopback bind.
- `auth.rateLimit` is seeded to a sane default (`maxAttempts 10 / windowMs 60000 / lockoutMs 300000`)
  when none is configured, for brute-force throttling. A user-set value is never overridden.

Env-driven fields stay authoritative across restarts; the rate-limit default is set-if-missing only.

## LinuxServer conventions

s6-overlay v3 layout under `root/etc/s6-overlay/s6-rc.d/`:

- `init-openclaw-config` (oneshot) — builds the `/config` tree, seeds `openclaw.json`, applies the auth
  variable, `lsiown`s to the runtime user. Linked into the base `init-config-end` bundle.
- `svc-openclaw` (longrun) — runs `node openclaw.mjs gateway --bind "$(openclaw-resolve-bind)" --port 18789`
  as `abc` via `s6-setuidgid`. Depends on the base `init-services` bundle (so it starts after all
  init stages).
- `/usr/local/bin/openclaw-resolve-bind` — single source of truth for the inbound bind, used by both
  the service and the config oneshot so they cannot disagree:

  | Condition | Bind |
  |---|---|
  | `OPENCLAW_GATEWAY_BIND` non-empty | that value, after alias normalization |
  | else `TAILSCALE_SERVE_PORT` non-empty | `loopback` |
  | else | `lan` |

  It emits **bind modes**, never addresses. Legacy host aliases supplied via
  `OPENCLAW_GATEWAY_BIND` are normalized (`127.0.0.1`/`localhost`/`::1` → `loopback`;
  `0.0.0.0`/`::` → `lan`, exact case-sensitive matches only) and anything else passes through
  verbatim so `auto`, `tailnet` and `custom` keep working. Earlier revisions of this image emitted
  the literal `127.0.0.1` on the Tailscale path, which is precisely the shape upstream documents as
  unsupported; the normalization exists so installs that copied that value out of the old README
  self-heal instead of carrying it forward.

  Two failure modes are guarded deliberately. The variables are tested for **non-empty**, not merely
  "set", because Unraid passes template variables through even when the field is blank — the same
  reason the oneshot already defends against an empty `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS`. And the
  callers fail **open to `lan`** if the helper is missing or errors: an empty `--bind` would either
  abort startup or silently fall through to upstream's `loopback` default, leaving a container that
  runs but cannot be reached through Docker port forwarding.

  The resolver prints **nothing** but the resolved value: its stdout *is* its return value, and both
  callers discard its stderr, so a warning raised there would either corrupt the bind value or
  vanish. The two human-facing notices — alias normalization, and the Tailscale/loopback warning —
  are emitted by `init-openclaw-config` instead, which already prints and runs before the gateway
  starts. Keep it that way; it is also what makes `docker exec <c> openclaw-resolve-bind` usable as
  a debugging probe.

  `bind` is inbound-only; OpenClaw reaching out to other containers is unaffected by it.

`HOME=/config` lands OpenClaw's `$HOME`-relative `~/.openclaw` on the persistent volume. `PUID`/`PGID`/
`UMASK`/`TZ` are delegated to the base image; there is no `CMD`/`ENTRYPOINT` (the base's `/init` is PID 1).

Note: `linuxserver/docker-project-template` is on the legacy s6-overlay v2 layout; the v3 conventions
here follow current mature LinuxServer images (e.g. `docker-code-server`, `docker-jellyfin`) and the
baseimage's own `s6-rc.d` tree.

**Custom-image branding (required for non-official images on the LSIO base).** Per LinuxServer's
[container-branding docs](https://docs.linuxserver.io/general/container-branding/), an image built on
their base must replace the startup banner so it doesn't misrepresent LinuxServer. This image ships
`root/etc/s6-overlay/s6-rc.d/init-adduser/branding` with its own banner (clearly marked unofficial /
not affiliated) and sets `ENV LSIO_FIRST_PARTY=false` so the base init does not overwrite it.

## Open upstream issues to track

- [openclaw#41881](https://github.com/openclaw/openclaw/issues/41881) — multi-arch (arm64/armv7) builds.
- [openclaw#61779](https://github.com/openclaw/openclaw/issues/61779) — gateway binds 127.0.0.1 inside
  the container, blocking Docker port forwarding unless `--bind lan` is set.
