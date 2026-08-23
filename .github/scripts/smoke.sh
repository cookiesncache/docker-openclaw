#!/usr/bin/env bash
# Boot built images and assert they actually work.
#
# Used by build.yml (between build and push, so a broken image never reaches :latest) and by
# ci.yml (on pull requests). Invoked as `bash .github/scripts/smoke.sh <image-ref>` so it does
# not depend on the executable bit surviving a Windows checkout.
#
# Two containers are booted, in parallel, because they exercise different bind paths:
#   $NAME     - no Tailscale variables. The historical default: bind mode `lan`.
#   $NAME_TS  - TAILSCALE_SERVE_PORT set. The Unraid "Use Tailscale + Serve" path, which binds
#               loopback. This path previously had ZERO coverage, which is exactly how a bind
#               value OpenClaw does not accept shipped to users: the old assertion only checked
#               that the resolver returned something non-empty, and "127.0.0.1" satisfies that.
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref>}"
BASE="smoke-$$"
NAME="${BASE}-default"
NAME_TS="${BASE}-tailscale"

cleanup() { docker rm -f "$NAME" "$NAME_TS" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail=0
bad() { echo "::error::$*"; fail=1; }

# Match without a pipe.
#
# `producer | grep -q PATTERN` is a trap under `set -o pipefail`: grep -q exits the moment it
# matches, closing the pipe, so the producer dies of SIGPIPE (141). pipefail then reports 141
# for the whole pipeline and a SUCCESSFUL match reads as a failure.
#
# Worse, it is size dependent: output small enough to fit the 64KB pipe buffer is written
# before grep exits, no signal is delivered, and the check passes. So it fails intermittently
# as a container gets chattier. That is exactly how the Tailscale-notice assertion passed in
# pr-smoke and then failed in build minutes later on the same commit.
#
# A here-string feeds grep from a temporary fd rather than a pipe, so there is no producer to
# signal. Capture command output into a variable first, then match against it.
has() { # <pattern> <text>
  grep -q "$1" <<< "$2"
}

TOKEN="$(openssl rand -hex 24)"

# Start both up front so their ~20s boots overlap rather than serialise.
docker run -d --name "$NAME" \
  -e PUID=1000 -e PGID=1000 \
  -e OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
  "$IMAGE" >/dev/null

docker run -d --name "$NAME_TS" \
  -e PUID=1000 -e PGID=1000 \
  -e OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
  -e TAILSCALE_SERVE_PORT=18789 \
  "$IMAGE" >/dev/null

wait_healthy() {
  local c="$1" i
  for i in $(seq 1 90); do
    if docker exec "$c" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
      echo "  [$c] gateway healthy after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "::error::[$c] gateway never became healthy"
  docker logs "$c"
  return 1
}

# ---------------------------------------------------------------------------
# Container 1: default path
# ---------------------------------------------------------------------------
echo "== default container =="
wait_healthy "$NAME"

# The native state-DB module only opens on gateway start; `openclaw.mjs --version` loads the
# module graph but never exercises it. A SQLite file here means the native module loaded
# successfully against the Node runtime copied from the upstream stage - which is the thing most
# likely to break when upstream changes its base image or Node major.
#
# Polled separately from /healthz: the gateway answers healthz within a few seconds, but the
# state database is opened asynchronously and lands slightly later.
#
# Paths are wrapped in `sh -c` so that running this script from Git Bash on Windows does not
# rewrite /config into a Windows path before it reaches the container.
db=0
for i in $(seq 1 60); do
  if docker exec "$NAME" sh -c 'test -f /config/.openclaw/state/openclaw.sqlite'; then
    echo "  state DB open after ${i}s"
    db=1
    break
  fi
  sleep 1
done
if [ "$db" != 1 ]; then
  echo "::error::state DB never appeared - the native state module likely failed to load"
  docker exec "$NAME" sh -c 'ls -la /config/.openclaw/state/' || true
  docker logs "$NAME"
  exit 1
fi

# ---------------------------------------------------------------------------
# Container 2: the Tailscale path, which is the whole reason the resolver exists
# ---------------------------------------------------------------------------
echo "== tailscale container =="
wait_healthy "$NAME_TS"   # a bind mode OpenClaw refuses would abort startup - this catches it

ts_bind="$(docker exec "$NAME_TS" openclaw-resolve-bind)"
if [ "$ts_bind" = "loopback" ]; then
  echo "  resolver returned 'loopback'"
else
  bad "with TAILSCALE_SERVE_PORT set the resolver returned '${ts_bind}', expected 'loopback'"
fi

# The config file must agree with the flag the service was launched with.
read_cfg_bind='console.log(JSON.parse(require("fs").readFileSync("/config/.openclaw/openclaw.json","utf8")).gateway.bind)'
cfg_bind="$(docker exec "$NAME_TS" node -e "$read_cfg_bind")"
if [ "$cfg_bind" = "loopback" ]; then
  echo "  openclaw.json gateway.bind is 'loopback'"
else
  bad "openclaw.json gateway.bind is '${cfg_bind}', expected 'loopback'"
fi

# The actual listener. This is the assertion that proves the bind mode took effect rather than
# being silently ignored: a tolerated-but-unhonoured value would still answer /healthz on loopback
# while ALSO listening on a wildcard address.
#
# Read from /proc/net/tcp{,6} rather than lsof. lsof returned NOTHING here - no rows, and no error
# we kept, because its stderr was discarded - while the gateway was demonstrably serving /healthz.
# Its behaviour in this container is not something to build an assertion on. /proc is the kernel's
# own table: always present, needs no package, stable format. Addresses are little-endian hex, so
# 127.0.0.1 is "0100007F" and 0.0.0.0 is "00000000"; state 0A is LISTEN; port 18789 is 0x4965.
read_listeners='
const fs = require("fs");
const PORT = 18789;
const hexPort = PORT.toString(16).toUpperCase().padStart(4, "0");
const out = [];
for (const entry of [["/proc/net/tcp", 4], ["/proc/net/tcp6", 6]]) {
  const file = entry[0], fam = entry[1];
  let txt;
  try { txt = fs.readFileSync(file, "utf8"); } catch (e) { continue; }
  for (const line of txt.split("\n").slice(1)) {
    const f = line.trim().split(/[ \t]+/);
    if (f.length < 4) continue;
    const parts = (f[1] || "").split(":");
    if (parts[1] !== hexPort || f[3] !== "0A") continue;
    const addr = parts[0];
    // /proc stores addresses as little-endian 32-bit words, so the hex is NOT a plain
    // big-endian address: 127.0.0.1 is "0100007F", and ::1 is
    // "00000000000000000000000001000000" - the 01 leads the final word rather than
    // trailing the string. Byte-swap each word back before classifying, or ::1 reads as
    // an unknown address and a correctly loopback-bound gateway looks wrong.
    const be = (hex) => hex.length % 8 !== 0 ? hex : hex.match(/.{8}/g)
      .map(w => w.slice(6, 8) + w.slice(4, 6) + w.slice(2, 4) + w.slice(0, 2)).join("");
    const a = be(addr).toUpperCase();
    let cls = "other";
    if (fam === 4) {
      if (a === "7F000001") cls = "loopback";               // 127.0.0.1
      else if (a === "00000000") cls = "wildcard";          // 0.0.0.0
      else if (/^7F/.test(a)) cls = "loopback";             // rest of 127/8
    } else {
      if (/^0{31}1$/.test(a)) cls = "loopback";             // ::1
      else if (/^0{32}$/.test(a)) cls = "wildcard";         // ::
      else if (/^0{20}FFFF7F/.test(a)) cls = "loopback";    // ::ffff:127.x.x.x
    }
    out.push("LISTEN ipv" + fam + " " + addr + " " + cls);
  }
}
console.log(out.join("\n"));
'
listeners="$(docker exec "$NAME_TS" node -e "$read_listeners" 2>&1 || true)"
echo "  listeners on 18789:"
if [ -n "$listeners" ]; then
  printf '%s\n' "$listeners" | sed 's/^/    /'
else
  echo "    (none)"
fi

if ! has '^LISTEN ' "$listeners"; then
  bad "nothing is listening on 18789 - expected a loopback listener with bind=loopback"
  echo "  --- diagnostics (stderr kept this time) ---"
  docker exec "$NAME_TS" sh -c 'cat /proc/net/tcp; echo ---tcp6---; cat /proc/net/tcp6' 2>&1 | sed 's/^/    /' || true
  docker exec "$NAME_TS" lsof -i -P -n 2>&1 | sed 's/^/    lsof: /' || true
elif has ' wildcard$' "$listeners"; then
  bad "gateway is listening on a wildcard address despite bind=loopback"
elif ! has ' loopback$' "$listeners"; then
  bad "gateway is listening on 18789 but not on loopback - expected loopback with bind=loopback"
fi

# The operator-facing warning. Someone who keeps the shipped port mapping loses the dashboard
# when they enable Tailscale, and this log line is the only thing that tells them why.
ts_log="$(docker logs "$NAME_TS" 2>&1 || true)"
if has 'Tailscale detected' "$ts_log"; then
  echo "  Tailscale notice present in container log"
else
  bad "the Tailscale/loopback startup notice is missing from the container log"
  printf '%s\n' "$ts_log" | tail -40
fi

# ---------------------------------------------------------------------------
# Resolver truth table
#
# Invoked as `bash <script>` rather than by its shebang. s6-overlay v3's with-contenv runs
# s6-envdir WITHOUT -i, so it overlays /run/s6/container_environment onto the existing
# environment: variables absent at boot pass through fine, but variables that were present at
# boot get stomped back to their boot values. Bypassing the shebang is therefore strictly
# required only to override a boot-set variable, and harmless otherwise - doing it uniformly
# keeps every row of this table behaving the same way.
#
# Which container a row runs in matters: `docker exec` inherits the container's boot
# environment, so TAILSCALE_SERVE_PORT exists only in $NAME_TS.
# ---------------------------------------------------------------------------
echo "== resolver truth table =="
resolves() { # container, label, expected, env assignments...
  local c="$1" label="$2" exp="$3"; shift 3
  local args=() e got
  for e in "$@"; do args+=(-e "$e"); done
  got="$(docker exec ${args[@]+"${args[@]}"} "$c" bash /usr/local/bin/openclaw-resolve-bind 2>/dev/null || true)"
  if [ "$got" = "$exp" ]; then
    printf '  PASS  %-44s -> %s\n' "$label" "$got"
  else
    bad "resolver: ${label} gave '${got}', expected '${exp}'"
  fi
}

# No Tailscale in scope.
resolves "$NAME"    "unset"                      lan
resolves "$NAME"    "BIND empty"                 lan         OPENCLAW_GATEWAY_BIND=
resolves "$NAME"    "BIND=lan"                   lan         OPENCLAW_GATEWAY_BIND=lan
resolves "$NAME"    "BIND=loopback"              loopback    OPENCLAW_GATEWAY_BIND=loopback
resolves "$NAME"    "BIND=tailnet (verbatim)"    tailnet     OPENCLAW_GATEWAY_BIND=tailnet
resolves "$NAME"    "BIND=auto (verbatim)"       auto        OPENCLAW_GATEWAY_BIND=auto
resolves "$NAME"    "BIND=127.0.0.1 (alias)"     loopback    OPENCLAW_GATEWAY_BIND=127.0.0.1
resolves "$NAME"    "BIND=localhost (alias)"     loopback    OPENCLAW_GATEWAY_BIND=localhost
resolves "$NAME"    "BIND=::1 (alias)"           loopback    OPENCLAW_GATEWAY_BIND=::1
resolves "$NAME"    "BIND=0.0.0.0 (alias)"       lan         OPENCLAW_GATEWAY_BIND=0.0.0.0
resolves "$NAME"    "BIND=:: (alias)"            lan         OPENCLAW_GATEWAY_BIND=::

# Tailscale in scope. The empty-string row is the important one: Unraid passes a blank advanced
# template field through as an empty string, and treating that as "set" would emit --bind "".
resolves "$NAME_TS" "TS + BIND unset"            loopback
resolves "$NAME_TS" "TS + BIND empty"            loopback    OPENCLAW_GATEWAY_BIND=
resolves "$NAME_TS" "TS + BIND=lan (override)"   lan         OPENCLAW_GATEWAY_BIND=lan

if [ "$fail" != 0 ]; then
  echo "::error::smoke test failed"
  exit 1
fi

echo "::notice::smoke test passed (both containers healthy, state DB open, bind=loopback honoured under Tailscale)"
