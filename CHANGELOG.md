# Changelog

Notable changes to this image. The packaging is versioned by the upstream OpenClaw release it
bundles; this file records changes to the packaging itself.

## Unreleased

### Changed — action may be required

**`OPENCLAW_ALLOW_INSECURE_AUTH` now defaults to `false` for new installs.**

Existing installs are **not** affected: the variable is only written to your config when you
actually set it, so an install that has been running with insecure auth enabled keeps it. Only a
fresh `/config` picks up the new default.

Why: the gateway's own startup check calls the old default out —
`security warning: dangerous config flags enabled: gateway.controlUi.allowInsecureAuth=true`.
Accepting an auth token over plain HTTP should be something you opt into, not something you inherit.

If pairing fails on a plain `http://` address after a fresh install, either put TLS in front (see
[Access](README.md#access)) or set `OPENCLAW_ALLOW_INSECURE_AUTH=true`. The container prints exactly
that hint at boot when insecure auth is off.

**The gateway's inbound bind is now conditional.**

| Condition | Bind |
|---|---|
| `OPENCLAW_GATEWAY_BIND` set to a non-empty value | that value, verbatim |
| otherwise, `TAILSCALE_SERVE_PORT` set (Unraid's Tailscale integration) | `127.0.0.1` |
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

### Added

- `OPENCLAW_GATEWAY_BIND` — advanced, empty by default. See the table above.
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
