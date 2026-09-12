# syntax=docker/dockerfile:1

# ---- upstream: source the prebuilt /app and the Node runtime it was built against ----
# OpenClaw's final stage is node:24-bookworm-slim (Debian, glibc, amd64), built from
# source via pnpm. We copy its /app (dist/ + pruned node_modules with the native state-DB
# module) rather than rebuild. This image is therefore amd64-only, like upstream.
#
# UPSTREAM_REF defaults to the floating tag so a bare `docker build .` works with no
# arguments. CI always overrides it with a digest reference, and refuses to publish
# anything that is not pinned (see .github/workflows/build.yml).
ARG UPSTREAM_REF=ghcr.io/openclaw/openclaw:latest
FROM ${UPSTREAM_REF} AS upstream

# ---- final: LinuxServer.io base (s6-overlay v3 + PUID/PGID + /config) ----
# Pinned by digest so the base cannot move under us; Dependabot's docker ecosystem
# proposes bumps as a one-line PR.
FROM ghcr.io/linuxserver/baseimage-ubuntu:noble@sha256:41788f272daa815df0c027ef84628194be062322cb01d6d86c53ecc4ea8a279c

# HOME=/config so OpenClaw's $HOME-relative ~/.openclaw lands on the persistent volume.
# LSIO_FIRST_PARTY=false: this is a custom/unofficial image on the LSIO base, so the base
# init must not overwrite our own init-adduser/branding (see container-branding docs).
ENV HOME="/config" \
    NODE_ENV="production" \
    OPENCLAW_DISABLE_BONJOUR="true" \
    LSIO_FIRST_PARTY="false"

# Cache-busting handle for the apt layer below, and its POSITION IS DELIBERATE.
#
# An ARG declared ABOVE a RUN joins that RUN's cache key - visible in `docker history` as the
# `RUN |n NAME=value ...` prefix - so changing APT_EPOCH forces this layer to re-execute and
# pick up current Ubuntu security updates for the packages installed here.
#
# Do NOT move it down beside BUILD_DATE and VERSION. Those sit at the end precisely so they do
# NOT invalidate this layer; this one exists to do the opposite. Moving it would silently
# restore the old behaviour, in which a warm layer cache let the monthly rebuild reuse
# months-old packages and publish an image differing only in its labels.
#
# It MUST be passed identically to BOTH build sites in build.yml - the smoke build and the
# build-push-action - or the image that gets smoke-tested is not the image that gets pushed.
# Both read a single value computed once by the gate step.
ARG APT_EPOCH
RUN \
  echo "**** install runtime packages (apt epoch: ${APT_EPOCH:-unset}) ****" && \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    hostname \
    lsof \
    openssl \
    procps \
    python3 && \
  echo "**** cleanup ****" && \
  apt-get clean && \
  rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/*

# Node runtime, taken from the upstream stage rather than NodeSource.
#
# This is the exact Node build the copied native modules were compiled against, so the ABI
# match is guaranteed by construction instead of by pinning NodeSource's floating 24.x head.
# It also removes a `curl | bash` of a third party's script running as root at build time.
# Verified: node is dynamically linked only against libdl/libstdc++/libm/libgcc_s/libpthread/
# libc, all present on noble; bookworm's glibc 2.36 -> noble's 2.39 is the forward-compatible
# direction; OpenSSL is statically linked, so the base's libssl is irrelevant.
COPY --from=upstream /usr/local/bin/node         /usr/local/bin/node
COPY --from=upstream /usr/local/lib/node_modules /usr/local/lib/node_modules
# Node's own license, covering its bundled components (OpenSSL, ICU, V8, zlib, ...). The
# NodeSource deb used to install this as /usr/share/doc/nodejs/copyright; a binary copy
# would otherwise drop it. npm's LICENSE rides along inside node_modules/npm.
COPY --from=upstream /usr/local/LICENSE          /licenses/NODEJS_LICENSE
RUN \
  ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
  ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
  ln -sf node /usr/local/bin/nodejs

# prebuilt OpenClaw application (node_modules compiled against the Node copied above)
COPY --from=upstream /app /app

# preserve OpenClaw's MIT notice alongside the bundled application (MIT requires it)
COPY THIRD_PARTY_NOTICES.md /licenses/THIRD_PARTY_NOTICES.md

# s6 service definitions + first-run init
COPY root/ /
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/init-openclaw-config/run \
    /etc/s6-overlay/s6-rc.d/svc-openclaw/run \
    /usr/local/bin/openclaw-resolve-bind

# Build metadata last: these ARGs change on every published build, and declaring them here
# keeps them from invalidating the cached apt/COPY layers above.
ARG BUILD_DATE
ARG VERSION
ARG UPSTREAM_REF
LABEL build_version="docker-openclaw version:- ${VERSION} built:- ${BUILD_DATE}"
LABEL maintainer="simsc"
# What this image's /app and Node runtime were actually built from. Ask any image with:
#   docker inspect -f '{{index .Config.Labels "io.cookiesncache.openclaw.upstream.ref"}}' <image>
LABEL io.cookiesncache.openclaw.upstream.ref="${UPSTREAM_REF}"

WORKDIR /app
EXPOSE 18789

# Restore upstream's health probe (lost when we copy only /app). /healthz is unauthenticated
# on loopback, so this works regardless of the auth posture; Node 24 has a global fetch().
HEALTHCHECK --interval=1m --timeout=10s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# No ENTRYPOINT/CMD on purpose: the baseimage's /init (s6-overlay) is PID 1 and
# supervises svc-openclaw. Signal handling/zombie reaping is s6's job, not tini's.
