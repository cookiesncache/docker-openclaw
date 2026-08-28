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

- **amd64 only, by choice rather than by constraint.** Both dependencies support arm64: upstream's
  `:latest` index carries a `linux/arm64` manifest alongside amd64, and so does the LSIO base at the
  digest pinned here (checked 2026-08-23).

  The Dockerfile itself likely needs no change. In a buildx multi-platform build `FROM
  ${UPSTREAM_REF}` resolves to the matching platform variant for each target and `COPY
  --from=upstream` follows it, so no `TARGETARCH` selection is required. That holds **only because
  both pins are index digests**: the gate resolves `{{.Manifest.Digest}}`, which on a multi-arch tag
  is the index, and the base pin is an index too. Pin either to a platform-specific manifest digest
  and per-platform resolution silently stops working - worth knowing before anyone tidies the
  pinning.

  The real blocker is the smoke test, not the build. `smoke.sh` boots containers and asserts against
  a live gateway, `--load` does not accept multi-platform output, and booting arm64 on an amd64
  runner needs QEMU - so build-locally-then-smoke-then-push would have to be restructured. The
  native state-DB module would also need the glibc argument below re-checked for arm64 rather than
  assumed to transfer. See the multi-arch tracking issue; out of scope while nobody has asked for it.
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

The logic lives in `.github/scripts/gate.sh`, not inline in the workflow, and that placement is
load-bearing: `build.yml` **is** one of the hashed inputs, so while the gate lived inside it every
edit to the gate moved the fingerprint and published an image to every install just to test a
decision. `gate.sh` chooses *which* image to build; it is not *in* the image, so it is correctly
outside the input set.

### Which upstream, not whether to build

The gate answers two independent questions, and they need two independent override flags —
collapsing them into a single `FORCE` was the original bug.

| Flag | Bypasses | Means |
|---|---|---|
| `FORCE_PUBLISH` | the fingerprint gate | "rebuild even though nothing changed" |
| `FORCE_ADOPT` | the age gate | "take the new upstream even if it is young" |

| Trigger | `FORCE_PUBLISH` | `FORCE_ADOPT` |
|---|---|---|
| `workflow_dispatch` with `force` | yes | no |
| `workflow_dispatch` with `adopt` | no | yes |
| `schedule`, monthly package refresh | see below | no |
| advisory match (below) | no | yes |
| anything else | no | no |

Repo-only changes are never blocked by upstream's clock: a fix under `root/` moves the fingerprint
and publishes immediately, built against the previously published upstream digest.

### Refreshing the apt packages, monthly and deterministically

Package refreshes and upstream releases are different artifacts and now use different mechanisms.
The LSIO base is pinned by digest, so *its* layers cannot move on their own — base updates arrive
only as Dependabot digest bumps. But the Dockerfile also installs eight packages from the Ubuntu
archive (`ca-certificates curl git hostname lsof openssl procps python3`), and those go stale
between rebuilds. With the fingerprint gate doing its job, an image could otherwise sit unrebuilt
for months while CVEs accumulated against them.

`APT_EPOCH` (`date -u +%Y-%m`) is passed as a build-arg declared **above** that apt layer, so it
joins the layer's cache key — visible in `docker history` as the `RUN |n NAME=value` prefix — and a
new month forces the packages to be reinstalled. It is computed once in `gate.sh`, folded into the
publish fingerprint, and passed to **both** build sites. So the first fingerprint-checking run of
each month publishes with fresh packages, and every later run that month is a no-op again.

This replaced a `day -eq 1` `FORCE_PUBLISH`, which was wrong three ways:

- It forced a **push, not a rebuild.** With a warm gha layer cache the apt layer was reused, so the
  "refresh" published an image differing only in its labels — a phantom update, no security benefit.
- **Staleness was unbounded, not capped at a month.** Every publish re-accesses that cache entry and
  resets its 7-day eviction clock, so a month busy enough to keep the cache warm carried the same
  packages forward indefinitely. It appeared to work only because the gate skips most days, leaving
  the cache usually cold by the 1st — an accident of eviction, not a design.
- **A dropped run skipped a whole month.** Schedule delivery is best-effort and `day -eq 1` was
  evaluated at run time. With the epoch in the fingerprint, the next run of the month publishes
  instead.

Two consequences worth expecting. A genuine publish early in a new month also refreshes packages,
which is a feature — the publish was happening anyway — but the layer churn is not a cache
regression. And a month in which Ubuntu shipped nothing for these eight packages still produces a
new digest, because re-running apt is never byte-identical (dpkg mtimes, `ld.so.cache`). Twelve
such updates a year is already accepted by the tagging policy below.

A candidate younger than three days is not adopted; `UP_BUILD` stays at the published digest and the
fingerprint therefore does not move, so a quiet day still publishes nothing.

**The age comes from GitHub's release record, not from the image.** `created` in the image config is
written by whoever built the image, so in the one scenario the cooldown defends against — a
compromised upstream build pipeline — an attacker could zero or backdate it and skip the wait. That
is not a privilege escalation (they already control the payload) but it is worse in a subtler way:
it removes the delay that exists precisely so somebody else has time to notice. The gate therefore
reads `published_at` from `GET /repos/openclaw/openclaw/releases/tags/{tag}`.

Three measurements shaped this, all 2026-08-23:

- GHCR's own push record would be the ideal source, but
  `/orgs/openclaw/packages/container/openclaw/versions` returns **401** unauthenticated and wants a
  token with `read:packages` for another organisation — i.e. a long-lived PAT in a repository that
  publishes container images. That is a worse trade than the problem it solves. The releases
  endpoint needs no token at all.
- **Release tags carry a `v` prefix that image labels do not.** `.../releases/tags/2026.7.1-2` is a
  404; `v2026.7.1-2` is a 200. A naive exact-match join would fail *every* run, and since a failed
  age lookup is now a red run, that would have turned the alarm into noise on day one.
- **`-N` re-pushes have their own releases.** `v2026.7.1-1` and `v2026.7.1-2` were published
  2026-08-04, three weeks after `v2026.7.1` (2026-07-13) — they do *not* inherit the base release's
  date. Keying off the release therefore does not shorten a re-push's soak time, which is what the
  change was originally expected to cost.

In the healthy case this moves nothing: the live `:latest` reported `created` 2026-08-04T00:45:59Z
against a release `published_at` of 2026-08-04T00:41:25Z, four and a half minutes apart. It moves
who is allowed to say it.

**The candidate must also outrank what we ship** (`version_newer`, dpkg not semver). The version
label lives in the same config blob as `created`, so sourcing the date from GitHub alone would only
stop an attacker *inventing* a timestamp — they could still *borrow* a real one by labelling the
image `2026.6.6`, whose genuine `published_at` is months old. Requiring the candidate to outrank the
shipping version forces them to name a release at least as new as ours, whose real publish date is
recent, so the cooldown still bites. Accepted cost: if upstream ever retags `:latest` to a
lower-numbered backport this holds until a higher release appears. Such releases exist — v2026.6.33
and v2026.6.34 were published 2026-08-08, *after* v2026.7.1-2 on 2026-08-04 — but `:latest` has
never moved to one, and the manual `adopt` dispatch is the escape hatch.

**There is deliberately no "published upstream is older than N days" escape hatch**, although one
was drafted. It measures the upstream *release's* age rather than how long we have been holding, so
once the shipped digest ages past N — which is the normal state between releases; the digest in
production while this was written was 18.8 days old — the clause stops applying and every new
candidate is adopted at age zero. That inverts the feature in exactly the steady state it exists
for. The escape hatches are the advisory check and a manual `adopt` dispatch instead. In exchange
the hold is unbounded in theory, which is why **every hold is logged with the candidate's age**: a
persistent hold has to be visible, because nothing bounds it automatically.

Failure directions are separated deliberately, and the split is now three ways rather than two.

A registry error reading the candidate's config fails **closed** (hold, warn, exit 0 — retry
tomorrow; the cost is one day, which is what the feature is for). Before holding, the published
digest is probed for existence: if upstream has garbage-collected it, holding would build `FROM` a
digest that no longer exists, so the candidate is adopted instead.

But anything that leaves the gate unable to establish a *trustworthy age* — no usable version label,
a candidate that does not outrank what we ship, an unreachable releases API, or a version with no
matching release — **holds and exits non-zero**. There is no fall-back to `created` in those
branches, and that omission is the point: falling back to the field this design exists to distrust,
in the exact case where the trustworthy source is missing, would defeat it. The old fail-**open** on
a missing `created` is gone because `created` is no longer read at all.

A2 is accepted risk, so there is no issue-notification channel — which makes a red run the only
signal that reaches anyone, and a good one: GitHub emails on workflow failure by default, and the
job is idempotent and runs daily, so a failed run costs at most one day. That only holds while
failures stay rare, so failure is reserved for "I could not make this decision safely" and is never
spent on an input that merely *accelerates* adoption. The advisory lookup keeps its warn-and-continue
behaviour for exactly that reason: losing it falls back to the cooldown you would have had anyway.

The hold is deliberately unbounded. Capping it would need a consecutive-failure counter, and there
is nowhere to keep one — a hold publishes nothing, so no annotation records it, and the alternatives
(the Actions cache, a repo variable) either add their own failure mode or need permissions this
workflow will not take.

**The age lookup is lazy, and the log now says so.** `release_published_at` is called only on the
branch that actually has a soak decision to make. The `adopt (unchanged)` short-circuit fires first
whenever the candidate digest equals the published one — the normal state between upstream releases
— and on that path there is no new artifact to age, so no request is made. `CAND_AGE` and
`CAND_PUBLISHED` therefore stay empty, which is correct and not a failure.

This was originally reported as a broken lookup, and the log line was why: it rendered the empty
values through `${…:-unknown}` and printed `released unknown, age unknownd` — a literal string where
a number belongs — which is indistinguishable from a failing API call. Three consecutive green runs
were investigated on that basis before the lookup was confirmed healthy (`v2026.7.1-1` returns
**200** anonymously with `published_at: 2026-08-04T00:41:25Z`). The clause now reports which of the
three things happened: `released <ts>, age <n>d` when the lookup resolved, `age lookup failed` when
it ran and did not (always alongside the `FAIL_REASON` naming which failure it was), and `age not
checked` when it was never attempted. `unknown` was never reachable by the numeric comparison —
`age_days` returns a decimal string or empty, and the `-lt` is guarded by a `-z` test — so this was
only ever a reporting defect, but it cost a real investigation.

### Adopting early when an advisory says to

The cooldown must not delay a disclosed vulnerability fix, and must not depend on anyone noticing
one. Each run reads `GET /repos/openclaw/openclaw/security-advisories?state=published` and sets
`FORCE_ADOPT` when the version **currently shipping** is inside a vulnerable range and the candidate
is outside it. The question is whether *we* are exposed, not whether an advisory exists.

Things that were not obvious and cost time to establish:

- **Compare with `dpkg --compare-versions`, not semver.** Advisory ranges carry the build suffix —
  `GHSA-3cvx-236h-m9fj` really reads `<= 2026.2.19-2`. semver treats `-2` as a *prerelease* and
  orders it **before** `2026.2.19`; dpkg treats it as revision 2 and orders it **after**. The
  advisory author means "every build through `-2`", which is dpkg's reading.
- **Never hand the npm operator to dpkg.** dpkg's `<` and `>` are obsolete aliases for `<=` and
  `>=`. The live feed contains `>= 2026.5.20, < 2026.6.9`, so a pass-through would make `2026.6.9`
  — the fixed release — test as still vulnerable, and force-adopt in the *unsafe* direction.
- **Filter on the package name.** `@openclaw/feishu`, `@openclaw/msteams` and `@openclaw/qqbot`
  advisories share the feed with near-identical ranges. Without the filter a plugin advisory would
  force-adopt an unvetted gateway release — the precise false positive the cooldown prevents. Those
  plugins are not even in this image; they install at runtime into `/config/.openclaw/npm`. Matched
  case-insensitively, because some advisories are filed against `Openclaw`/`OpenClaw`.
- **Ranges are not uniformly formatted.** Eight live entries omit the space after the operator
  (`<=2026.5.5`), and a naive `${part%% *}` split also dies on the leading space that an
  `IFS=','` split leaves on every comparator after the first. Both shapes are handled, and both are
  covered by `gate.sh --self-test`, which runs on every PR against a real `dpkg`.
- **Compare both the full and the base version.** The image label carries the build suffix
  (`2026.7.1-1`) while advisory ranges are usually bare, so `2026.6.6-1` would sort *outside*
  `<= 2026.6.6` under dpkg. Exposure is checked against both forms.

Everything here fails closed on adoption and never fails the job: an API error, an unparseable
range, or a missing version annotation all fall back to the normal cooldown, which is the wait you
would have had anyway.

**Stated limitation.** This catches vulnerabilities OpenClaw publishes as repository security
advisories. A fix shipped quietly inside a release with no GHSA gets the normal cooldown. Matching
release-note text for `CVE-|GHSA-|security` would widen coverage, but a false positive there means
adopting an unvetted release — exactly what the gate exists to prevent — so advisory-only is the
defensible default. The feed is also read newest-first, and only as far back as `ADV_MAX_PAGES`
requests of 100 entries reach — measured 2026-08-23, three requests cover roughly three months.
That is sufficient only because an advisory affecting the version we are *currently* shipping is by
definition newly published and therefore at the top of it.

That endpoint is cursor-paginated, following the `after` cursor in the `Link` response header; it
ignores a `page` parameter rather than rejecting one. Until 2026-08 this code passed `page`, so all
three requests returned the *same* newest 100 advisories — one month of history, not three, and two
of every three requests wasted. The window figure quoted here before was right by coincidence and
the mechanism it named was not, which is why the cap is now described in requests.

Worth doing once, outside CI: watch the OpenClaw repository's security advisories in GitHub's UI so
a human gets an email too. The pipeline must not depend on it.

**Fallback** if the copied native module ever fails to load: rebuild from source on the base image, or
`npm rebuild` the offending module against the installed Node.

### Upstream tag drift

`:latest` moving is upstream's decision, and watching it means the gate cannot, from the digest
alone, distinguish *"upstream has published nothing new"* from *"upstream published something new
and did not move the tag"*. Both present as a matching fingerprint and a silent green run.

The second case is not hypothetical. Measured 2026-08-27:

| tag | digest |
| --- | --- |
| `latest` | `sha256:2f5ce88…` |
| `2026.7.1-1` | `sha256:2f5ce88…` |
| `2026.7.1-2` | `sha256:8789721d…` |
| `2026.6.34` | `sha256:47d342ba…` |

`2026.7.1-2` is a **distinct image**, published 2026-08-04, and `:latest` has never moved to it — so
this image sat on `2026.7.1-1` for 23 days with nothing in the logs suggesting anything else was
available. It is a non-security fix (npm plugin singleton-array metadata, upstream #108336) and no
published advisory reaches what we ship — the newest cap at `<= 2026.6.6` — so nothing was at risk.
The invisibility was the defect, not the delay.

`latest_stable_version` therefore reads the releases feed on `adopt (unchanged)` runs only and warns
when a higher non-prerelease release exists than the one `:latest` resolves to. Specifics worth
keeping:

- **It warns; it never holds and never fails the job.** Drift changes no decision — the build still
  consumes whatever `:latest` resolves to — and a red run is never spent on a condition with a safe
  fallback. **Note that `adopt` does not reach it either**: `FORCE_ADOPT` bypasses the age gate, but
  `UP_CANDIDATE` is always whatever `:latest` resolves to, so an unpromoted release is never a
  candidate in the first place. The warning is genuinely informational — the drift clears itself
  when upstream promotes the tag (the release is by then well past the cooldown, so the next
  scheduled run adopts it with no intervention). Taking it sooner means repointing `UPSTREAM`.
- **Ranked by `version_newer`, not by date.** Upstream's maintenance lines publish out of version
  order: v2026.6.34 landed 2026-08-08, *after* v2026.7.1-2 on 2026-08-04. "Newest by date" would
  warn every day about a backport we deliberately outrank; ranking by version makes that silent.
- **Prereleases and drafts are dropped.** Upstream ships betas continuously (2026.8.1-beta.2/.3),
  and a daily warning about one is exactly the routine noise that makes a signal worthless.
- **Bounded to one page** (100 releases, roughly a year at upstream's cadence). This only reports,
  and a drift that falls off that window is not one a warning was going to rescue.
- It costs one request, on no-op runs only, and self-clears the moment upstream promotes the tag.

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
