#!/usr/bin/env bash
# Decide (a) WHICH upstream digest to build against and (b) WHETHER to publish at all.
#
# These are two independent questions and they need two independent override flags. Collapsing
# them into a single FORCE was the bug this replaces.
#
#   FORCE_PUBLISH  bypasses the fingerprint gate -> "rebuild even though nothing changed"
#   FORCE_ADOPT    bypasses the age gate         -> "take the new upstream even if it is young"
#
# Distro security patches and upstream releases are different artifacts. The monthly rebuild
# refreshes apt/distro layers inside the pinned base; those live in the base image, not in
# OpenClaw's /app. So it needs FORCE_PUBLISH and has no business touching adoption - on the 1st
# with a two-day-old upstream you get fresh base layers on the previously vetted application,
# which is precisely the intent.
#
# Writes `publish`, `upstream` and `hash` to $GITHUB_OUTPUT. `upstream` is the digest actually
# built against, so the io.cookiesncache.openclaw.upstream.digest annotation cannot claim a
# digest the build did not consume.
#
# This file is deliberately NOT part of REPO_INPUTS (see build.yml): it decides which image to
# build, it is not *in* the image. Keeping it out of the fingerprint means iterating on gate
# logic does not publish an image to every installed user just to test a decision.
#
# Self-test the version-range parser with no registry and no Docker:
#     bash .github/scripts/gate.sh --self-test
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-ghcr.io/openclaw/openclaw}"
ADVISORY_REPO="${ADVISORY_REPO:-openclaw/openclaw}"
COOLDOWN_DAYS="${COOLDOWN_DAYS:-3}"

# ---------------------------------------------------------------------------
# Version ranges
#
# GitHub advisory ranges are npm-style comparators, AND-ed, comma separated:
#     "<= 2026.6.6"   "= 2026.6.6"   ">= 2026.5.20, < 2026.6.9"   "<= 2026.2.19-2"
#
# Compared with `dpkg --compare-versions`, NOT semver. OpenClaw ships several image builds of one
# release as 2026.7.1, 2026.7.1-1, 2026.7.1-2, and advisories are written against that scheme:
# GHSA-3cvx-236h-m9fj really says "<= 2026.2.19-2". semver would read `-2` as a PRE-release and
# order it BEFORE 2026.2.19; dpkg reads it as revision 2 and orders it AFTER. The advisory author
# means "every build through -2 is affected", which is dpkg's reading.
#
# The npm operator is never handed to dpkg directly: dpkg's `<` and `>` are obsolete aliases for
# `<=` and `>=` (control-file compatibility), while npm's are strict. The live feed contains
# ">= 2026.5.20, < 2026.6.9", so passing `<` through would make version 2026.6.9 - the fixed
# release - test as still vulnerable. Translate explicitly.
# ---------------------------------------------------------------------------
npm_op_to_dpkg() {
    case "$1" in
        '<')  printf 'lt' ;;
        '<=') printf 'le' ;;
        '>')  printf 'gt' ;;
        '>=') printf 'ge' ;;
        '=')  printf 'eq' ;;
        *)    return 1 ;;   # ^, ~, bare version, anything unrecognised -> caller fails closed
    esac
}

# in_range <version> <range>  -> exit 0 when the version is inside the range.
# Anything unparseable returns non-zero: for the caller this means "not exposed", i.e. it fails
# CLOSED on adoption, back to the normal cooldown.
in_range() {
    local v="$1" range="$2"
    local -a parts
    local part op ver rest dop

    [ -n "$v" ] && [ "$v" != "null" ] || return 1
    [ -n "$range" ] || return 1

    IFS=',' read -ra parts <<< "$range"
    [ "${#parts[@]}" -gt 0 ] || return 1

    for part in "${parts[@]}"; do
        # `read` collapses arbitrary leading/trailing whitespace, which ${part%% *} does not:
        # after an IFS=',' split the second element of ">= a, < b" is " < b" WITH a leading
        # space, and ${part%% *} would yield an empty operator and silently kill every
        # multi-comparator range.
        read -r op ver rest <<< "$part"
        if [ -z "${ver:-}" ]; then
            # No space after the operator - "<=2026.5.5". Not hypothetical: eight entries in the
            # live feed are written this way. Split the token instead of failing closed, or those
            # advisories would never match anything.
            if [[ "${op:-}" =~ ^([<>]=?|=)(.+)$ ]]; then
                op="${BASH_REMATCH[1]}"
                ver="${BASH_REMATCH[2]}"
            fi
        fi
        [ -n "${op:-}" ] && [ -n "${ver:-}" ] || return 1
        dop="$(npm_op_to_dpkg "$op")" || return 1
        dpkg --compare-versions "$v" "$dop" "$ver" 2>/dev/null || return 1
    done
    return 0
}

# Upstream's image label carries the build suffix (2026.7.1-1) while advisories target the npm
# package, whose versions are usually bare - yet GHSA-3cvx-236h-m9fj proves authors sometimes
# include the suffix. Neither "always strip" nor "never strip" is right, so try both forms.
in_range_either() { # <version> <range>
    local v="$1" range="$2"
    in_range "$v" "$range" && return 0
    [ "${v%%-*}" != "$v" ] && in_range "${v%%-*}" "$range" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# --self-test: exercise the parser against the shapes the live feed actually contains.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    t() { # description, expect(in|out), version, range
        local desc="$1" expect="$2" v="$3" r="$4" got
        if in_range_either "$v" "$r"; then got=in; else got=out; fi
        if [ "$got" = "$expect" ]; then
            printf '  PASS  %-46s %s vs %-28s -> %s\n' "$desc" "$v" "$r" "$got"
        else
            printf '  FAIL  %-46s %s vs %-28s -> %s (want %s)\n' "$desc" "$v" "$r" "$got" "$expect"
            st_fail=1
        fi
    }

    # GHSA-3cvx-236h-m9fj, the real thing: "<= 2026.2.19-2", patched 2026.2.21.
    t "exposed version inside suffixed range"   in  "2026.2.19"   "<= 2026.2.19-2"
    t "the fix is outside it"                   out "2026.2.21"   "<= 2026.2.19-2"
    t "an earlier build is inside"              in  "2026.2.19-1" "<= 2026.2.19-2"
    t "the last affected build is inside"       in  "2026.2.19-2" "<= 2026.2.19-2"

    # Multi-comparator: the common shape, and the one a single-comparator fixture cannot cover.
    t "multi-comparator, inside"                in  "2026.6.7"    ">= 2026.5.20, < 2026.6.9"
    t "multi-comparator, below lower bound"     out "2026.5.19"   ">= 2026.5.20, < 2026.6.9"
    t "multi-comparator, at lower bound"        in  "2026.5.20"   ">= 2026.5.20, < 2026.6.9"
    # The boundary that proves npm `<` is not being handed to dpkg as `<=`.
    t "multi-comparator, AT the strict < bound" out "2026.6.9"    ">= 2026.5.20, < 2026.6.9"
    t "suffixed build at the strict < bound"    out "2026.6.9-1"  ">= 2026.5.20, < 2026.6.9"

    t "exact match"                             in  "2026.6.6"    "= 2026.6.6"
    t "exact non-match"                         out "2026.6.7"    "= 2026.6.6"
    t "plain upper bound"                       in  "2026.6.6"    "<= 2026.6.6"
    t "suffixed build vs bare upper bound"      in  "2026.6.6-1"  "<= 2026.6.6"

    # Live feed shapes that a small sample misses.
    t "no space after operator"                 in  "2026.5.4"    "<=2026.5.5"
    t "no space after operator, outside"        out "2026.5.6"    "<=2026.5.5"
    t "no space, multi-comparator"              in  "2026.5.25"   ">=2026.5.12,<2026.5.26"
    # Prerelease bounds. dpkg reads "-beta.1" as a Debian revision (NEWER than the bare version)
    # where semver reads it as a prerelease (OLDER). For bounds well away from the version being
    # tested the two agree, which covers every real case here; the divergence only bites when the
    # shipping version equals a bound's base, and then it errs toward "exposed" - a spurious
    # adopt, and only ever of a release that genuinely fixes a published advisory.
    t "beta lower bound, below range"           out "2026.4.1"    ">= 2026.4.12-beta.1, < 2026.6.6"
    t "beta lower bound, inside range"          in  "2026.5.1"    ">= 2026.4.12-beta.1, < 2026.6.6"
    t "beta lower bound, above range"           out "2026.7.1"    ">= 2026.4.12-beta.1, < 2026.6.6"
    t "beta upper bound, well below"            in  "2026.5.1"    "<= 2026.5.19-beta.2"

    # Fail closed on anything we do not understand.
    t "caret range unsupported"                 out "2026.6.6"    "^2026.6.0"
    t "tilde range unsupported"                 out "2026.6.6"    "~2026.6.0"
    t "bare version unsupported"                out "2026.6.6"    "2026.6.6"
    t "empty range"                             out "2026.6.6"    ""
    t "empty version"                           out ""            "<= 2026.6.6"
    t "literal null version"                    out "null"        "<= 2026.6.6"
    t "garbage operator"                        out "2026.6.6"    "~> 2026.6.6"

    if [ "$st_fail" != 0 ]; then
        echo "::error::gate.sh range-parser self-test failed"
        exit 1
    fi
    echo "gate.sh self-test passed"
    exit 0
fi

# ---------------------------------------------------------------------------
# Registry probes
# ---------------------------------------------------------------------------
: "${IMAGE:?IMAGE must be set}"
: "${UPSTREAM:?UPSTREAM must be set}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

# `imagetools inspect --format '{{json .Image}}'` reads manifests plus the config blob - no layer
# pull. For a multi-arch index it returns a map keyed by platform; for a single manifest, the bare
# config. Upstream's index now carries linux/arm64 plus two attestation manifests, so key
# linux/amd64 explicitly instead of taking whatever sorts first. Field case is normalised because
# buildx has shipped both OCI-style (`created`) and Docker-style (`Created`) marshalling.
image_config() { # <pinned ref> -> config JSON, or empty on failure
    docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null \
      | jq -c 'if type != "object" then empty
               elif (has("created") or has("Created") or has("config") or has("Config")) then .
               else (.["linux/amd64"] // empty) end' 2>/dev/null || true
}
cfg_created() { printf '%s' "$1" | jq -r '(.created // .Created) // empty' 2>/dev/null || true; }
cfg_version() {
    printf '%s' "$1" \
      | jq -r '((.config.Labels // .Config.Labels) // {})["org.opencontainers.image.version"] // empty' \
        2>/dev/null || true
}

# age_days <rfc3339> -> whole days, or empty when the timestamp is absent or zeroed. An upstream
# that sets SOURCE_DATE_EPOCH would zero it; that is a permanent property, not a transient error,
# and the caller treats the two differently.
age_days() {
    local c="$1" epoch now
    [ -n "$c" ] || { printf ''; return 0; }
    case "$c" in 0001-01-01*|1970-01-01T00:00:00*) printf ''; return 0 ;; esac
    epoch="$(date -u -d "$c" +%s 2>/dev/null)" || { printf ''; return 0; }
    [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null || { printf ''; return 0; }
    now="$(date -u +%s)"
    printf '%s' $(( (now - epoch) / 86400 ))
}

UP_CANDIDATE="$(docker buildx imagetools inspect "$UPSTREAM" --format '{{.Manifest.Digest}}')"

PUB_RAW="$(docker buildx imagetools inspect "$IMAGE:latest" --raw 2>/dev/null || printf '{}')"
jq_ann() { printf '%s' "$PUB_RAW" | jq -r ".annotations[\"$1\"] // \"\"" 2>/dev/null || printf ''; }
PUBLISHED="$(jq_ann 'io.cookiesncache.inputs')"
UP_PUBLISHED="$(jq_ann 'io.cookiesncache.openclaw.upstream.digest')"
PUB_VER="$(jq_ann 'org.opencontainers.image.version')"

REPO_INPUTS="$(git rev-parse HEAD:Dockerfile HEAD:root HEAD:.dockerignore HEAD:.github/workflows/build.yml | sha256sum | cut -c1-16)"

# ---------------------------------------------------------------------------
# Force flags
# ---------------------------------------------------------------------------
FORCE_PUBLISH=false
FORCE_ADOPT=false

if [ "${EVENT_NAME:-}" = "workflow_dispatch" ]; then
    # Two separate inputs on purpose. A dispatch that implied BOTH would mean re-running the
    # workflow merely to read its logs republishes byte-shuffled content as a phantom update to
    # every install, and adopts a possibly hours-old upstream.
    [ "${IN_FORCE:-false}" != "true" ] || FORCE_PUBLISH=true
    [ "${IN_ADOPT:-false}" != "true" ] || FORCE_ADOPT=true
fi

if [ "${EVENT_NAME:-}" = "schedule" ] && [ "$(date -u +%-d)" -eq 1 ]; then
    FORCE_PUBLISH=true   # monthly rebuild for apt/security updates inside the pinned base
fi

# ---------------------------------------------------------------------------
# Candidate metadata
# ---------------------------------------------------------------------------
CAND_CFG="$(image_config "${UPSTREAM_REPO}@${UP_CANDIDATE}")"
CAND_VER=""
CAND_AGE=""
CAND_INSPECTABLE=false
if [ -n "$CAND_CFG" ]; then
    CAND_INSPECTABLE=true
    CAND_VER="$(cfg_version "$CAND_CFG")"
    CAND_AGE="$(age_days "$(cfg_created "$CAND_CFG")")"
fi

# ---------------------------------------------------------------------------
# Advisory-driven FORCE_ADOPT
#
# The cooldown must not delay a disclosed vulnerability fix, and must not depend on anyone
# noticing one. Adopt immediately when the candidate fixes something the version we are CURRENTLY
# SHIPPING is exposed to - the question is whether we are exposed, not whether an advisory exists.
#
# Limitation, stated plainly: this catches vulnerabilities OpenClaw publishes as repository
# security advisories. A fix shipped quietly inside a release with no GHSA gets the normal
# cooldown. Matching release-note text for CVE-|GHSA-|security would widen coverage, but a false
# positive there means adopting an unvetted release, which is exactly what this gate exists to
# prevent. Advisory-only is the defensible default.
#
# Every failure path here leaves FORCE_ADOPT false and never fails the job: the worst case is the
# cooldown you would have had anyway.
# ---------------------------------------------------------------------------
if [ "$FORCE_ADOPT" != "true" ] \
   && [ -n "$PUB_VER" ] && [ "$PUB_VER" != "null" ] \
   && [ -n "$CAND_VER" ] && [ "$CAND_VER" != "null" ] \
   && [ "$UP_CANDIDATE" != "$UP_PUBLISHED" ]; then

    # Paginated, with a hard cap. Measured 2026-08: this project publishes advisories in bulk -
    # 300 entries spans roughly ONE month, not the year you might assume - so the window is much
    # narrower than the page count suggests.
    #
    # That is still sufficient, for a reason worth writing down: an advisory that affects the
    # version we are CURRENTLY SHIPPING is, by definition, newly published, so it sits at the top
    # of this feed. Older advisories cap at older versions and cannot affect a current PUB_VER.
    # The window only matters if the gate stops running for weeks while upstream keeps shipping,
    # and in that case the daily build has already stopped being daily.
    #
    # GITHUB_TOKEN is a rate-limit courtesy only - the endpoint serves another repo's published
    # advisories unauthenticated, which is also the fallback when the token is absent or rejected.
    adv_fetch_page() { # <page> -> JSON array on stdout, non-zero on failure
        local page="$1" out url
        url="https://api.github.com/repos/${ADVISORY_REPO}/security-advisories?state=published&per_page=100&page=${page}"
        # -fsS matters: without -f, curl exits 0 on an HTTP 403/404 and hands jq a JSON *object*
        # ({"message": "API rate limit exceeded"}) rather than an array, so the fallback would
        # never fire and the object would be parsed as if it were data.
        if [ -n "${GITHUB_TOKEN:-}" ] \
           && out="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
                          -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url" 2>/dev/null)"; then
            printf '%s' "$out"; return 0
        fi
        if out="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)"; then
            printf '%s' "$out"; return 0
        fi
        return 1
    }

    RANGES=""
    adv_any=false
    for adv_page in $(seq 1 "${ADV_MAX_PAGES:-3}"); do
        if ! ADV="$(adv_fetch_page "$adv_page")"; then
            if [ "$adv_any" = false ]; then
                echo "::warning::could not read ${ADVISORY_REPO} security advisories - falling back to the normal cooldown"
            else
                echo "::warning::advisory page ${adv_page} could not be read - checking only the pages already fetched"
            fi
            break
        fi
        adv_any=true

        adv_count="$(printf '%s' "$ADV" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0')"
        [ -n "$adv_count" ] || adv_count=0

        # The feed mixes packages: @openclaw/feishu, @openclaw/msteams and @openclaw/qqbot
        # advisories sit alongside openclaw ones with near-identical version ranges. Without this
        # filter a PLUGIN advisory would force-adopt an unvetted gateway release - the precise
        # false positive the cooldown prevents. (Those plugins are not even in this image; they
        # install at runtime into /config/.openclaw/npm.)
        #
        # Matched case-insensitively on the BARE name, because some advisories are filed against
        # "Openclaw"/"OpenClaw". That still excludes the scoped @openclaw/* plugin packages, whose
        # names do not equal "openclaw" under any casing.
        adv_ranges="$(printf '%s' "$ADV" | jq -r '
            (if type == "array" then . else [] end)
            | .[]? | .vulnerabilities[]?
            | select(.package.ecosystem == "npm"
                     and ((.package.name // "") | ascii_downcase) == "openclaw")
            | .vulnerable_version_range // empty' 2>/dev/null || true)"
        [ -z "$adv_ranges" ] || RANGES="${RANGES}${adv_ranges}
"

        # A short page is the last page.
        [ "$adv_count" -ge 100 ] 2>/dev/null || break
    done

    # Deduplicate: the feed repeats identical ranges heavily (one measurement: 282 entries
    # collapsing to a few dozen distinct ranges), and each survivor costs up to four dpkg calls.
    [ -z "$RANGES" ] || RANGES="$(printf '%s' "$RANGES" | sort -u)"

    if [ -n "$RANGES" ]; then
        while IFS= read -r range; do
            [ -n "$range" ] || continue
            if in_range_either "$PUB_VER" "$range" && ! in_range_either "$CAND_VER" "$range"; then
                FORCE_ADOPT=true
                echo "::notice::advisory match: shipping ${PUB_VER} is inside '${range}' and candidate ${CAND_VER} is not - adopting immediately"
                break
            fi
        done <<< "$RANGES"
    fi
fi

# ---------------------------------------------------------------------------
# Adoption decision
#
# There is deliberately NO "published upstream is older than N days" escape hatch. Such a clause
# measures the upstream release's age, not how long we have been holding, so once the shipped
# digest ages past N the cooldown stops applying at all and every new candidate is adopted at age
# zero - inverting the feature in the steady state. The escape hatches are the advisory check
# above and a manual `adopt` dispatch. In exchange the hold is unbounded in theory, which is why
# a hold is logged loudly every run rather than passing silently.
# ---------------------------------------------------------------------------
UP_BUILD="$UP_CANDIDATE"
DECISION="adopt"

if [ "$FORCE_ADOPT" = "true" ]; then
    DECISION="adopt (forced)"
elif [ -z "$UP_PUBLISHED" ]; then
    DECISION="adopt (nothing published yet)"
elif [ "$UP_CANDIDATE" = "$UP_PUBLISHED" ]; then
    DECISION="adopt (unchanged)"
elif ! docker buildx imagetools inspect "${UPSTREAM_REPO}@${UP_PUBLISHED}" --raw >/dev/null 2>&1; then
    # Holding would build FROM a digest that no longer exists. Adopting is the only buildable
    # choice. (This is why the probe is explicit rather than an accident of some other lookup.)
    DECISION="adopt (published upstream digest no longer resolves)"
    echo "::warning::published upstream digest ${UP_PUBLISHED} no longer resolves - adopting the candidate"
elif [ "$CAND_INSPECTABLE" != "true" ]; then
    # Transient registry/network failure: fail CLOSED and retry tomorrow. Cost is one day of
    # delay, which is what this feature is for. Failing open would zero the cooldown on exactly
    # the day an outage coincides with a fresh release.
    UP_BUILD="$UP_PUBLISHED"
    DECISION="hold (could not inspect candidate - treating as young)"
    echo "::warning::could not inspect ${UPSTREAM_REPO}@${UP_CANDIDATE} - holding until the next run"
elif [ -z "$CAND_AGE" ]; then
    # created missing or zeroed: a permanent upstream property, not an outage. Fail OPEN, or we
    # would never adopt again.
    DECISION="adopt (candidate has no usable created timestamp)"
    echo "::warning::candidate image has no usable 'created' timestamp - adopting without an age check"
elif [ "$CAND_AGE" -lt "$COOLDOWN_DAYS" ]; then
    UP_BUILD="$UP_PUBLISHED"
    DECISION="hold (candidate is ${CAND_AGE}d old, cooldown ${COOLDOWN_DAYS}d)"
fi

HASH="$(printf '%s\n%s\n' "$UP_BUILD" "$REPO_INPUTS" | sha256sum | cut -c1-16)"

# ---------------------------------------------------------------------------
# Publish decision
# ---------------------------------------------------------------------------
if [ "$FORCE_PUBLISH" != "true" ] && [ -n "$PUBLISHED" ] && [ "$PUBLISHED" = "$HASH" ]; then
    PUBLISH=false
else
    PUBLISH=true
fi

{
    echo "publish=$PUBLISH"
    echo "upstream=$UP_BUILD"
    echo "hash=$HASH"
} >> "$GITHUB_OUTPUT"

# A hold must never be silent: nothing bounds it automatically, so this log line is how a
# persistent hold becomes visible.
echo "::notice::upstream: candidate=${UP_CANDIDATE} (${CAND_VER:-unknown}, age ${CAND_AGE:-unknown}d) published=${UP_PUBLISHED:-none} (${PUB_VER:-unknown}) -> ${DECISION}"
if [ "$PUBLISH" = "true" ]; then
    echo "::notice::publishing: fingerprint ${HASH} (published was '${PUBLISHED:-none}', force_publish=${FORCE_PUBLISH}, force_adopt=${FORCE_ADOPT}), building against ${UP_BUILD}"
else
    echo "::notice::no input changed (fingerprint ${HASH}) - nothing to publish."
fi
