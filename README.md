# docker-openclaw

[![build](https://github.com/cookiesncache/docker-openclaw/actions/workflows/build.yml/badge.svg)](https://github.com/cookiesncache/docker-openclaw/actions/workflows/build.yml)

> ⚠️ **Unofficial, LinuxServer.io-*style* image — not affiliated with, maintained by, or endorsed by
> [LinuxServer.io](https://www.linuxserver.io/).** It follows their `PUID`/`PGID` + s6-overlay + `/config`
> conventions and mirrors their GPL-3.0 license, but is an independent, self-hosted build.

> **Status: scaffolded, not yet built/tested.** A self-hosted, [LinuxServer.io](https://www.linuxserver.io/)-style
> Docker image for the [OpenClaw](https://github.com/openclaw/openclaw) gateway. Built for our own use —
> *not* dependent on LinuxServer adopting it — but following their `PUID`/`PGID` + s6-overlay + `/config`
> conventions. No Docker on the authoring machine, so it must be built on a host (e.g. the Unraid box).

## Why this exists

The official image (`ghcr.io/openclaw/openclaw:latest`) runs as a fixed `uid 1000` and writes state to
`$HOME/.openclaw`. On hosts where the bind mount isn't owned by 1000 (e.g. Unraid `appdata`, `99:100`),
the gateway boots then dies:

```
EACCES: permission denied, mkdir '/home/node/.openclaw/state'
```

This image adopts the LinuxServer permission model: a fixed internal user (`abc`) is remapped to your
`PUID`/`PGID` at startup and `/config` is chowned for you — so the error can't happen. See
[NOTES.md](NOTES.md) for the full upstream facts and the debugging history behind this.

## How it's built (architecture)

Multi-stage, **amd64-only** (upstream publishes no arm64 yet):

1. **`upstream` stage** — `ghcr.io/openclaw/openclaw:latest`, used only as a source to copy the
   prebuilt `/app` (its `dist/` + pruned `node_modules`, including the native state-DB module).
2. **final stage** — `ghcr.io/linuxserver/baseimage-ubuntu:noble`. Installs **Node 24** (matching
   upstream's ABI so the copied native module loads), copies `/app`, and adds an s6 service.

`HOME=/config`, so OpenClaw's `~/.openclaw` resolves onto the persistent volume at
`/config/.openclaw/{openclaw.json,state,workspace}`.

```
root/etc/s6-overlay/s6-rc.d/
├── init-openclaw-config/   oneshot: mkdir tree, seed openclaw.json, lsiown to abc
├── svc-openclaw/           longrun: s6-setuidgid abc → node openclaw.mjs gateway --bind lan
└── user/contents.d/        registers both in the user bundle
```

> **ABI warning:** the base must stay glibc (Ubuntu/Debian) and Node must stay major **24**. An Alpine
> (musl) base or a different Node major will make the prebuilt state-DB `.node` binary crash on load.

## Build & run

```bash
# clone onto the Docker host, then:
cd docker-openclaw
cp .env.example .env          # set OPENCLAW_GATEWAY_TOKEN + ANTHROPIC_API_KEY
docker compose build
docker compose up -d
docker compose logs -f        # watch it boot; expect the OpenClaw banner + a listening line
```

Then open `http://<host-ip>:18789/`.

### Unraid notes

- Set `PUID=99` / `PGID=100` (nobody:users) in the compose/template so it matches `appdata` ownership —
  no `chown` ever needed.
- Map `/config` → `/mnt/user/appdata/openclaw`.
- For Tailscale, layer Unraid's Tailscale toggle on top (Post Arguments = flags only, never shell).
- **Auth posture is a variable:** `OPENCLAW_ALLOW_INSECURE_AUTH` defaults to `true` — the gateway runs
  HTTP behind a TLS terminator (Tailscale serve / reverse proxy) that provides real HTTPS, so the
  gateway only ever sees localhost HTTP. Set it `false` only to require HTTPS at the gateway itself.

## Deploy on Unraid (Community Apps)

The Unraid template is [`templates/openclaw.xml`](templates/openclaw.xml). It drives the Docker UI
(port, `/config`, PUID/PGID, token, API key) and is what makes the app show up in Community Apps (CA).

**Prerequisite — the image must be pullable.** Unraid pulls `<Repository>` when you apply a template,
so push the image to a registry first. GHCR matches the `cookiesncache` identity and the planned
Actions build:

```bash
# on the Unraid host (once the repo is on GitHub):
git clone https://github.com/cookiesncache/docker-openclaw.git
cd docker-openclaw
docker build -t ghcr.io/cookiesncache/openclaw:latest .
echo "$GHCR_PAT" | docker login ghcr.io -u cookiesncache --password-stdin
docker push ghcr.io/cookiesncache/openclaw:latest    # then mark the GHCR package Public
```

**Surface it in Community Apps — two options:**

1. **Private (immediate, no moderation) — recommended for personal use.** Copy the template onto the
   box; CA lists it when you search `private`:
   ```bash
   mkdir -p /boot/config/plugins/community.applications/private
   cp templates/openclaw.xml /boot/config/plugins/community.applications/private/
   ```
   CA → search **private** → **OpenClaw** → Install → fill in token/key → Apply.

2. **Public (moderated, optional, later).** Keep the template in this public repo, then request
   addition to the CA app feed via the Unraid forum template-repositories thread. After approval it
   appears in CA search for everyone.

You can also add this repo's URL under **Docker → Docker Repositories → Template repositories** to get
the template in the "Add Container" dropdown without CA.

> Building locally on Unraid with the **exact** tag in `<Repository>` can work, but a pushed (Public)
> GHCR package is the reliable path — Unraid's apply step tries to pull and a missing registry image
> can fail the install.

## Status / TODO

- [x] Confirm no existing `linuxserver/openclaw` (it's an open slot; other community images aren't LSIO-style).
- [x] Decide build strategy: copy prebuilt `/app` from upstream onto the LSIO base (see [NOTES.md](NOTES.md)).
- [x] Scaffold Dockerfile + s6-overlay v3 service tree + compose/env.
- [x] Author the Unraid Community Apps template ([templates/openclaw.xml](templates/openclaw.xml)).
- [x] Adversarial LSIO audit; fixed s6 dep wiring (F1), seed→`/defaults` (F7), `.dockerignore` (F5). See [NOTES.md](NOTES.md).
- [ ] **Build & smoke-test on the Unraid host** (first real validation).
- [ ] Push the image to GHCR and make the package Public (so the template can pull).
- [ ] Drop the template in `community.applications/private/` on Unraid and install.
- [x] Point the CA tile `<Icon>` at the official OpenClaw CA icon (`selfhosters/unRAID-CA-templates`), matching the official tile.
- [x] Preserve the original optional provider keys / bot tokens in the template (transparency).
- [ ] Confirm the native state-DB module loads on Noble/Node 24 (the ABI assumption).
- [ ] Pin upstream by digest instead of `:latest` (audit F2/F3 — capture the digest at build time).
- [x] Gate `allowInsecureAuth` behind `OPENCLAW_ALLOW_INSECURE_AUTH` (default `true`; TLS terminated in front) (audit F7).
- [x] Add GPL-3.0 `LICENSE` mirroring LinuxServer (audit F5).
- [x] GitHub Actions builds + pushes to GHCR ([.github/workflows/build.yml](.github/workflows/build.yml)); weekly upstream rebuild.
- [ ] Make the GHCR `openclaw` package **Public** (one-time, after first build) so Unraid can pull.
- [ ] arm64 — blocked on upstream ([openclaw#41881](https://github.com/openclaw/openclaw/issues/41881)).

## Notes on LinuxServer.io adoption

Not being pursued — upstream didn't read as receptive and we'd rather not depend on a third party.
The conventions are still followed, so if that changes the repo is already shaped for it. Process and
requirements are recorded in the git history of this file / [NOTES.md](NOTES.md) if ever revisited.

## License

[GPL-3.0](LICENSE), mirroring [LinuxServer.io's licensing](https://github.com/linuxserver). This is an
independent, **unofficial** project — not affiliated with or endorsed by LinuxServer.io. OpenClaw itself
is licensed separately by its authors; see [openclaw/openclaw](https://github.com/openclaw/openclaw).

## Sources

- [openclaw/openclaw](https://github.com/openclaw/openclaw) · [docs](https://docs.openclaw.ai/install/docker)
- [docker-project-template](https://github.com/linuxserver/docker-project-template) ·
  [Understanding PUID/PGID](https://docs.linuxserver.io/general/understanding-puid-and-pgid/) ·
  [s6-overlay](https://github.com/just-containers/s6-overlay)
