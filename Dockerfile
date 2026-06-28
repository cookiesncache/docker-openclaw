# syntax=docker/dockerfile:1

# ---- upstream: source the prebuilt /app ----
# OpenClaw's final stage is node:24-bookworm-slim (Debian, glibc, amd64), built from
# source via pnpm. We copy its /app (dist/ + pruned node_modules with the native state-DB
# module) rather than rebuild. This image is therefore amd64-only, like upstream.
FROM ghcr.io/openclaw/openclaw:latest AS upstream

# ---- final: LinuxServer.io base (s6-overlay v3 + PUID/PGID + /config) ----
FROM ghcr.io/linuxserver/baseimage-ubuntu:noble

ARG BUILD_DATE
ARG VERSION
LABEL build_version="docker-openclaw version:- ${VERSION} built:- ${BUILD_DATE}"
LABEL maintainer="simsc"

# HOME=/config so OpenClaw's $HOME-relative ~/.openclaw lands on the persistent volume.
ENV HOME="/config" \
    NODE_ENV="production" \
    OPENCLAW_DISABLE_BONJOUR="true"

RUN \
  echo "**** install runtime packages ****" && \
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
  echo "**** install nodejs 24 (MUST match upstream ABI for the native state-DB module) ****" && \
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
  apt-get install -y --no-install-recommends nodejs && \
  echo "**** cleanup ****" && \
  apt-get clean && \
  rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/*

# prebuilt OpenClaw application (node_modules compiled against Node 24 / glibc)
COPY --from=upstream /app /app

# preserve OpenClaw's MIT notice alongside the bundled application (MIT requires it)
COPY THIRD_PARTY_NOTICES.md /licenses/THIRD_PARTY_NOTICES.md

# s6 service definitions + first-run init
COPY root/ /
RUN chmod +x \
    /etc/s6-overlay/s6-rc.d/init-openclaw-config/run \
    /etc/s6-overlay/s6-rc.d/svc-openclaw/run

WORKDIR /app
EXPOSE 18789

# No ENTRYPOINT/CMD on purpose: the baseimage's /init (s6-overlay) is PID 1 and
# supervises svc-openclaw. Signal handling/zombie reaping is s6's job, not tini's.
