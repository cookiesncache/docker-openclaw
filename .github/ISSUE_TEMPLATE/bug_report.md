---
name: Bug report
about: Report a problem with the docker-openclaw image (packaging), not OpenClaw itself
labels: bug
---

<!--
For bugs in OpenClaw the application, please use the upstream tracker:
https://github.com/openclaw/openclaw/issues
This tracker is for the image/packaging (Dockerfile, s6 services, template, env handling).
-->

**Image version**
- `build_version` label: <!-- docker inspect -f '{{ index .Config.Labels "build_version" }}' openclaw -->
- OpenClaw version (startup banner / `node /app/openclaw.mjs --version`):

**Host / deployment**
- Unraid version (or other host):
- How you run it: CA template / docker-compose / docker run
- PUID/PGID and access method (Tailscale serve / reverse proxy / direct `http://ip:18789`):

**What happened**
<!-- Clear description of the problem and what you expected instead. -->

**Logs**
<!-- Relevant output from `docker logs openclaw`. Redact tokens/keys. -->

```
paste logs here
```
