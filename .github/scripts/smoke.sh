#!/usr/bin/env bash
# Boot a built image and assert it actually works.
#
# Used by build.yml (between build and push, so a broken image never reaches :latest) and
# by ci.yml (on pull requests). Invoked as `bash .github/scripts/smoke.sh <image-ref>` so
# it does not depend on the executable bit surviving a Windows checkout.
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref>}"
NAME="smoke-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" \
  -e PUID=1000 -e PGID=1000 \
  -e OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 24)" \
  "$IMAGE" >/dev/null

ok=0
for i in $(seq 1 90); do
  if docker exec "$NAME" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    echo "gateway healthy after ${i}s"
    ok=1
    break
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  echo "::error::gateway never became healthy"
  docker logs "$NAME"
  exit 1
fi

# The native state-DB module only opens on gateway start; `openclaw.mjs --version` loads
# the module graph but never exercises it. A SQLite file here means the native module
# loaded successfully against the Node runtime copied from the upstream stage - which is
# the thing most likely to break when upstream changes its base image or Node major.
#
# Polled separately from /healthz: the gateway answers healthz within a few seconds, but
# the state database is opened asynchronously and lands slightly later.
#
# Paths are wrapped in `sh -c` so that running this script from Git Bash on Windows does
# not rewrite /config into a Windows path before it reaches the container.
db=0
for i in $(seq 1 60); do
  if docker exec "$NAME" sh -c 'test -f /config/.openclaw/state/openclaw.sqlite'; then
    echo "state DB open after ${i}s"
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

# The bind resolver must always yield a non-empty value: an empty --bind would leave a
# container that runs but cannot be reached through Docker port forwarding.
BIND="$(docker exec "$NAME" openclaw-resolve-bind)"
if [ -z "$BIND" ]; then
  echo "::error::bind resolver returned an empty value"
  exit 1
fi

echo "::notice::smoke test passed (healthz 200, state DB open, bind=${BIND})"
