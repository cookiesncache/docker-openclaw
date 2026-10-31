# Changelog

Notable changes to this image. The packaging is versioned by the upstream OpenClaw release it
bundles; this file records changes to the packaging itself.

## Unreleased

### Changed — action may be required

**The base image is now Ubuntu 26.04 LTS (`resolute`), up from 24.04 (`noble`).**

OpenClaw itself is unaffected: its application and Node runtime are copied unchanged from the
official image. What changes is the Ubuntu userland around it, which matters if you run your own
scripts or tools inside the container.

**If you created a Python virtualenv under `/config`, recreate it.** `python3` is now 3.14 (was
3.12), and a virtualenv is tied to the interpreter that created it. Scripts that import a module
removed by [PEP 594](https://peps.python.org/pep-0594/) in Python 3.13 (`cgi`, `crypt`, `imghdr`,
`pipes`, `telnetlib` and others) also stop working.

Other tools in the container:

| Tool | 24.04 | 26.04 |
|---|---|---|
| `python3` | 3.12 | 3.14 |
| `git` | 2.43 | 2.53 |
| `openssl` (command-line tool) | 3.0 | 3.5 |
| `curl` | 8.5 | 8.18 |

Most coreutils — `mkdir`, `chown`, `chmod`, `ln`, `date`, `ls`, `cat` and others — are now the
Rust rewrite (uutils), which is Ubuntu 26.04's default. `cp`, `mv`, `rm`, `df` and `true` remain
GNU, and every GNU tool is still installed with a `gnu` prefix (`gnudate`, `gnuls`, …) for a script
that depends on a GNU-only flag.

To roll back, pin the last `-ls` tag published before this change — `2026.9.8-ls79` at the time of
writing (see [Updating](README.md#updating)).
26.04 has standard support until about 2031, two years past 24.04.

**`OPENCLAW_ALLOW_INSECURE_AUTH` is removed.**

OpenClaw retired `gateway.controlUi.allowInsecureAuth`; it already had no effect, and from
OpenClaw 2026.9.8 the gateway refuses to start while the key is in `openclaw.json`. The container
now deletes the key from your config on every boot and ignores the variable, printing a warning if
it is set to `true`. You can drop it from your compose file or template.

Nothing about pairing changes: the Control UI pairs a device only from a secure context — an
`https://` URL or `http://localhost`. If you reach it over plain `http://<lan-ip>:18789`, put TLS in
front (see [Access](README.md#access)).

**The gateway's inbound bind is now conditional.**

| Condition | Bind |
|---|---|
| `OPENCLAW_GATEWAY_BIND` set to a non-empty value | that value, after alias normalization |
| otherwise, `TAILSCALE_SERVE_PORT` set (Unraid's Tailscale integration) | `loopback` |
| otherwise | `lan` — unchanged |

Tailscale Serve runs inside the container and proxies to loopback, so binding the LAN as well only
widens the surface. **If you run Tailscale *and* a published `18789` port, or something on the
docker network reaches into the gateway, you go from reachable-both-ways to Tailscale-only.**

Restore the old behaviour with:

```
OPENCLAW_GATEWAY_BIND=lan
```

Note that `bind` is inbound-only — OpenClaw reaching *out* to other containers is unaffected and
needs no configuration.

A published Docker port cannot reach a loopback-bound process (the forward DNATs to `eth0`, not
`lo`), so with Tailscale enabled `http://<host-ip>:18789` stops working whether or not you remove
the port mapping. The container cannot see host-side port publishing, so it prints a notice at
startup rather than trying to correct it.

### Fixed

**Image updates that change OpenClaw's database schema no longer take the gateway down.**

The service started the gateway directly with `node openclaw.mjs gateway`. Upstream's image starts
it through `docker-entrypoint.mjs`, which runs `openclaw doctor --fix --non-interactive` first,
and that Doctor pass is the only step that advances the agent and state database schemas. The
gateway itself refuses an old schema. So when an update raised the schema (2026.9.8 needed agent
schema 24, 2026.10.5 needs 25), the gateway exited on every start with
`uses schema version N; stop active agents and run openclaw doctor --fix`. s6 restarted it
indefinitely and the container showed only "unhealthy".

The service now launches through upstream's adapter, so Doctor runs on every start and the gateway
takes over the same PID once it finishes. Doctor backs up each database before migrating it.
Expect the first boot after a schema-changing update to take a minute or two longer. Normal boots
add a few seconds.

**If your container is currently stuck**, updating to this image fixes it on the next start with no
manual steps. Until then the manual fix is:

```bash
docker exec <container> s6-svc -d /run/service/svc-openclaw
docker exec -u abc -e HOME=/config -w /app <container> node openclaw.mjs doctor --fix --non-interactive
docker exec <container> s6-svc -u /run/service/svc-openclaw
```

CI now fails the build if the startup Doctor pass is missing from the boot log. A fresh volume
boots healthy either way, so the health check alone could not catch this.

**`gateway.bind` is now a bind *mode*, not a host address.**

The Tailscale path wrote the literal string `127.0.0.1` into `gateway.bind` and passed it to
`--bind`. OpenClaw's configuration reference defines `bind` as one of `auto`, `loopback` (default),
`lan`, `tailnet` or `custom`, and documents host aliases (`0.0.0.0`, `127.0.0.1`, `localhost`,
`::`, `::1`) as unsupported there. It now emits `loopback`.

If you set `OPENCLAW_GATEWAY_BIND` to a host address yourself, it is normalized to the matching
mode — `127.0.0.1`/`localhost`/`::1` → `loopback`, `0.0.0.0`/`::` → `lan` — and the container
logs that it did so. Any other value still passes through untouched. Existing installs self-heal on
the next boot: the config oneshot rewrites `gateway.bind` every start, so no manual edit of
`openclaw.json` is needed.

CI now boots a container with `TAILSCALE_SERVE_PORT` set and asserts the gateway is healthy and
listening on loopback only. That path previously had no coverage, which is how this shipped.

### Changed

- **Image tags.** `:latest` and the bare version tag (`:2026.7.1`) still exist and still float. New:
  an immutable per-build tag, `:2026.7.1-1-ls<N>`, following LinuxServer's convention — **this is the
  tag to pin.** It also preserves upstream's build suffix, so `2026.7.1-1` and `2026.7.1-2` no longer
  collapse onto one tag.
- **The short-commit tag (`:52dca30`) is no longer published.** It was never a pin: most publishes are
  triggered by upstream moving with no repo commit, so the same tag was re-pushed over different
  content — `:52dca30` (commit dated 2026-06-29) was serving an image built 2026-08-17. Existing such
  tags remain in the registry but are frozen. The commit is still recorded as the
  `org.opencontainers.image.revision` annotation.

### Added

- `OPENCLAW_GATEWAY_BIND` — advanced, empty by default. See the table above.
- `libgomp1` and `openssh-client`, matching upstream's runtime packages. Managed llama.cpp local
  models need `libgomp1` (the `llama-server` build links OpenMP), and the SSH sandbox backend
  (`agents.defaults.sandbox.backend: "ssh"`) runs `ssh` directly, so it used to fail with
  `spawn ssh ENOENT` here. Git remotes over SSH now work too.
- `/licenses/NODEJS_LICENSE` in the image: Node.js's full license including its bundled components.
- `io.cookiesncache.openclaw.upstream.ref` label — ask any image exactly what it was built from:
  ```bash
  docker inspect -f '{{index .Config.Labels "io.cookiesncache.openclaw.upstream.ref"}}' ghcr.io/cookiesncache/openclaw:latest
  ```

### Security

- The upstream OpenClaw image is pinned by digest at build time; the build refuses to publish an
  unpinned reference, and the resolved digest is recorded as both an image label and an index
  annotation.
- The LinuxServer base image is pinned by digest, tracked by Dependabot.
- Node.js is copied from the upstream stage instead of installed via
  `curl https://deb.nodesource.com/... | bash -`, removing a third-party script executed as root at
  build time — and guaranteeing the runtime matches the ABI the bundled native modules were built
  against.
- All GitHub Actions are pinned to commit SHAs; Dependabot keeps the pins current and security
  updates auto-merge behind a required smoke-test check.

### Fixed

- Rebuilds that change nothing are no longer published, so installs stop seeing update prompts for
  images whose only difference was the build timestamp. The publish gate now fingerprints the
  *content* of the build inputs rather than the branch head, so documentation commits no longer
  trigger a rebuild.
- The image is now boot-tested — gateway reaches `/healthz`, state DB opens — before any push, on
  every path including the scheduled upstream-tracking build.
