#!/usr/bin/env bash
# Decide (a) WHICH upstream digest to build against and (b) WHETHER to publish at all.
#
# These are two independent questions and they need two independent override flags. Collapsing
# them into a single FORCE was the bug this replaces.
#
#   FORCE_PUBLISH  bypasses the fingerprint gate -> "rebuild even though nothing changed"
#   FORCE_ADOPT    bypasses the age gate         -> "take the new upstream even if it is young"
#
# The age gate reads GitHub's release record (published_at), NOT the image config's `created`.
# `created` is written by whoever built the image, so in the one scenario the cooldown defends
# against - a compromised upstream build pipeline - an attacker could zero or backdate it and switch
# the delay off. The cooldown's whole value is the detection window it buys somebody else, so the
# field establishing it must be one the artifact cannot write. See release_published_at() and
# version_newer() below for the full reasoning.
#
# When a trustworthy age cannot be established the gate HOLDS and exits non-zero. A red run is the
# only signal that reaches anyone here, so it is reserved for "I could not make this decision
# safely" and is never spent on a condition that has a safe fallback - if failures become routine
# the signal is worthless and this whole design collapses.
#
# Distro security patches and upstream releases are different artifacts. APT_EPOCH (below)
# refreshes the packages this image installs on top of the pinned base once a month, without
# touching upstream adoption: on a month boundary with a two-day-old upstream you get fresh
# packages on the previously vetted application, which is precisely the intent.
#
# Writes `publish`, `upstream` and `hash` to $GITHUB_OUTPUT. `upstream` is the digest actually
# built against, so the io.cookiesncache.openclaw.upstream.digest annotation cannot claim a
# digest the build did not consume.
#
# This file is deliberately NOT part of REPO_INPUTS (see build.yml): it decides which image to
# build, it is not *in* the image. Keeping it out of the fingerprint means iterating on gate
# logic does not publish an image to every installed user just to test a decision.
#
# Self-test the version-range parser and the version guards with no registry and no Docker:
#     bash .github/scripts/gate.sh --self-test
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-ghcr.io/openclaw/openclaw}"
ADVISORY_REPO="${ADVISORY_REPO:-openclaw/openclaw}"
COOLDOWN_DAYS="${COOLDOWN_DAYS:-3}"
RELEASES_REPO="${RELEASES_REPO:-openclaw/openclaw}"
# Overridable so "point the gate at an unreachable API" is a one-line test rather than a code edit.
GITHUB_API="${GITHUB_API:-https://api.github.com}"

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
# Candidate version guards
#
# The candidate's version string is hostile input: it comes from the SAME image config blob as the
# timestamp this gate no longer trusts, and it ends up in a request path. Both helpers are pure, so
# --self-test covers them with no network, no Docker and no registry.
# ---------------------------------------------------------------------------

# version_ok <version> -> exit 0 when the string is safe to put in a URL path.
# A whitelist on purpose. Real labels look like 2026.7.1-1 or 2026.8.1-beta.2; anything else is an
# age-establishment failure, not something to sanitise around.
version_ok() {
    local v="$1"
    [ -n "$v" ] && [ "$v" != "null" ] || return 1
    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 1
    return 0
}

# version_newer <candidate> <published> -> exit 0 when candidate strictly outranks what we ship.
#
# Without this, sourcing the date from GitHub is only a PROVENANCE improvement: a compromised build
# could no longer invent a timestamp, but it could still BORROW a real one by labelling itself with
# an old release - 2026.6.6 carries a genuine published_at from June - and skip the cooldown exactly
# as zeroing `created` did. Requiring the candidate to outrank what we ship forces an attacker to
# name a release at least as new as ours, whose real publish date is recent, so the cooldown bites.
#
# dpkg, not semver - the same reasoning as the advisory ranges above. 2026.7.1-1 gt 2026.7.1 and
# 2026.8.1-beta.2 gt 2026.7.1-1 both hold, so re-pushes and betas order the way upstream means them.
#
# Accepted cost, stated plainly: if upstream ever retags :latest to a LOWER-numbered backport this
# holds and fails every day until a higher release appears. Such releases do exist - v2026.6.33 and
# v2026.6.34 were published 2026-08-08, after v2026.7.1-2 on 2026-08-04 - but :latest has never
# moved to one. The escape hatch is the manual `adopt` dispatch.
version_newer() {
    local cand="$1" pub="$2"
    [ -n "$cand" ] && [ "$cand" != "null" ] || return 1
    [ -n "$pub" ]  && [ "$pub"  != "null" ] || return 1
    dpkg --compare-versions "$cand" gt "$pub" 2>/dev/null || return 1
    return 0
}

# release_tag_candidates <version> -> newline-separated release tags to try, most-specific first.
#
# Exact forms first (v-prefixed, then bare) - upstream normally cuts one release per exact version
# label. Only if BOTH miss does release_published_at fall back to these same two forms with
# everything from the FIRST hyphen stripped (%%, not %: "2026.7.1-rc-1" must strip to the release
# base "2026.7.1", not the still-suffixed "2026.7.1-rc"). Pure and self-contained so --self-test
# can prove the dedupe and the %%-vs-% distinction with no network.
release_tag_candidates() {
    local ver="$1" base="${1%%-*}"
    printf '%s\n' "v${ver}" "${ver}"
    # No hyphen means base == ver, so the stripped forms would just repeat the exact ones above -
    # skip them rather than spending two more requests for zero benefit on every total miss.
    [ "$base" = "$ver" ] || printf '%s\n' "v${base}" "${base}"
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

    # ---- version_newer: the replay / borrowed-release guard --------------------------------
    tn() { # description, expect(new|old), candidate, published
        local desc="$1" expect="$2" c="$3" p="$4" got
        if version_newer "$c" "$p"; then got=new; else got=old; fi
        if [ "$got" = "$expect" ]; then
            printf '  PASS  %-46s %-18s over %-14s -> %s\n' "$desc" "$c" "$p" "$got"
        else
            printf '  FAIL  %-46s %-18s over %-14s -> %s (want %s)\n' "$desc" "$c" "$p" "$got" "$expect"
            st_fail=1
        fi
    }
    # Real shapes. Measured 2026-08: upstream mints a distinct RELEASE per -N re-push
    # (v2026.7.1-1 and v2026.7.1-2 were published 2026-08-04, three weeks after v2026.7.1), so
    # re-pushes carry their own soak clock rather than inheriting the base release's date.
    tn "build suffix outranks its base release"  new "2026.7.1-1"      "2026.7.1"
    tn "later build suffix outranks earlier"     new "2026.7.1-2"      "2026.7.1-1"
    tn "next release outranks a suffixed build"  new "2026.8.1"        "2026.7.1-2"
    tn "beta outranks the previous release"      new "2026.8.1-beta.2" "2026.7.1-1"
    # The attack this guard exists to stop: a real but OLD release, borrowed for its genuine date.
    tn "borrowed older release is rejected"      old "2026.6.6"        "2026.7.1-1"
    tn "same version, different digest"          old "2026.7.1-1"      "2026.7.1-1"
    tn "base cannot replace its own re-push"     old "2026.7.1"        "2026.7.1-1"
    tn "empty candidate"                         old ""                "2026.7.1-1"
    tn "literal null candidate"                  old "null"            "2026.7.1-1"
    tn "empty published"                         old "2026.7.1-1"      ""

    # ---- version_ok: this string reaches a request path ------------------------------------
    tv() { # description, expect(ok|bad), version
        local desc="$1" expect="$2" v="$3" got
        if version_ok "$v"; then got=ok; else got=bad; fi
        if [ "$got" = "$expect" ]; then
            printf '  PASS  %-46s %-24s -> %s\n' "$desc" "'$v'" "$got"
        else
            printf '  FAIL  %-46s %-24s -> %s (want %s)\n' "$desc" "'$v'" "$got" "$expect"
            st_fail=1
        fi
    }
    tv "plain release"                           ok  "2026.7.1"
    tv "build suffix"                            ok  "2026.7.1-1"
    tv "beta"                                    ok  "2026.8.1-beta.2"
    tv "empty"                                   bad ""
    tv "literal null"                            bad "null"
    tv "path traversal"                          bad "../../etc/passwd"
    tv "embedded space"                          bad "2026.7.1 -1"
    tv "command separator"                       bad "2026.7.1;id"
    tv "query injection"                         bad "2026.7.1?per_page=1"
    tv "leading dash"                            bad "-2026.7.1"
    tv "over length"                             bad "$(printf '2%.0s' $(seq 1 200))"

    # ---- release_tag_candidates: the tag-fallback list itself ------------------------------
    tc() { # description, version, expected candidates...
        local desc="$1" v="$2"; shift 2
        local -a want=("$@") got=()
        mapfile -t got < <(release_tag_candidates "$v")
        if [ "${#got[@]}" = "${#want[@]}" ] && [ "${got[*]}" = "${want[*]}" ]; then
            printf '  PASS  %-46s %-14s -> %s\n' "$desc" "$v" "${got[*]}"
        else
            printf '  FAIL  %-46s %-14s -> %s (want %s)\n' "$desc" "$v" "${got[*]}" "${want[*]}"
            st_fail=1
        fi
    }
    tc "suffixed version: 4 candidates, exact forms first"    "2026.7.1-2"     "v2026.7.1-2" "2026.7.1-2" "v2026.7.1" "2026.7.1"
    tc "bare version dedupes to exactly 2 candidates"         "2026.7.1"       "v2026.7.1" "2026.7.1"
    tc "multi-hyphen version strips at the FIRST hyphen only" "2026.7.1-rc-1"  "v2026.7.1-rc-1" "2026.7.1-rc-1" "v2026.7.1" "2026.7.1"

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

# gh_release_by_tag <tag> [anon] -> release JSON on stdout.
#   0  HTTP 200      2  HTTP 404 (authoritative: no such release)      3  anything else
#
# Deliberately NOT `curl -f`, unlike adv_fetch_page below. That call must tell a JSON array from an
# error object, which is exactly what -f is for. This one must tell a 404 from a transport failure,
# which -f flattens into a single non-zero exit - so it reads %{http_code} and branches explicitly.
# The two are different on purpose; do not unify them.
gh_release_by_tag() {
    local t="$1" body code
    local -a auth=()
    [ "${2:-}" = "anon" ] || [ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    body="$(curl -sS --max-time 20 -w '\n%{http_code}' \
                 -H 'Accept: application/vnd.github+json' ${auth[@]+"${auth[@]}"} \
                 "${GITHUB_API}/repos/${RELEASES_REPO}/releases/tags/${t}" 2>/dev/null)" || return 3
    code="${body##*$'\n'}"
    case "$code" in
        200) printf '%s' "${body%$'\n'*}"; return 0 ;;
        404) return 2 ;;
        *)   return 3 ;;
    esac
}

# release_published_at <version> -> RFC3339 published_at on stdout.
#   0  found      2  no release matches      3  API unreachable / unexpected status
#
# The point of this function: `created` in the image config is written by whoever built the image,
# so it cannot establish an age the gate is willing to act on. published_at is GitHub's own record.
#
# The semantically ideal source would be GHCR's record of when the DIGEST was pushed, but
# /orgs/openclaw/packages/container/openclaw/versions returns 401 unauthenticated (measured
# 2026-08-23) and wants a token with read:packages for another organisation - i.e. a long-lived PAT
# in a repository that publishes container images. That is a worse trade than the problem it solves.
# The releases endpoint carries published_at, is public, and needs no token at all (also measured).
#
# The two exit codes are distinct on purpose. "No release matches" and "API unreachable" produce the
# same behaviour but are different diagnoses, and a red run that cannot say which is worth far less.
#
# The stripped-tag fallback (see release_tag_candidates) exists because upstream has shipped an
# image labelled ...-N with no dedicated release for that exact build, while the base version's
# release does exist. Refusing that match turns an upstream naming quirk into a hold that repeats
# every day forever - the routine-failure collapse this design cannot survive (see file header).
# It narrows, but does not remove, the "no release in any form" anomaly check below: a candidate
# matched on a stripped tag inherits that base release's published_at rather than having one of
# its own. The load-bearing property is untouched either way - age still comes from a real GitHub
# release, never the image's own `created` - so this is a narrower anomaly detector, not a weaker
# provenance one. Always logged with a `::warning::`, never silent.
release_published_at() {
    local ver="$1" tag body ts rc unreachable=0
    local -a tags
    mapfile -t tags < <(release_tag_candidates "$ver")

    # See release_tag_candidates() above for what's tried, in what order, and why.
    for tag in "${tags[@]}"; do
        if body="$(gh_release_by_tag "$tag")"; then
            :
        else
            rc=$?
            [ "$rc" != 2 ] || continue
            # A rejected or expired token 401s where an anonymous request would have worked, and
            # this endpoint needs no token at all - the token is only rate-limit courtesy.
            if [ -n "${GITHUB_TOKEN:-}" ] && body="$(gh_release_by_tag "$tag" anon)"; then
                :
            else
                rc=$?
                [ "$rc" = 2 ] || unreachable=1
                continue
            fi
        fi
        ts="$(printf '%s' "$body" | jq -r '.published_at // empty' 2>/dev/null || true)"
        # A 200 carrying no published_at (a draft) is not a clean "no such release".
        [ -n "$ts" ] || { unreachable=1; continue; }
        # Stderr, not stdout: CAND_PUBLISHED is filled by $(...) capturing this function's stdout,
        # so anything printed here would corrupt it. A direct write to an inherited fd like stderr
        # is unaffected by the subshell $(...) forks for the capture - only variable ASSIGNMENTS
        # die at that boundary (see adv_fetch_page's comment on the same trap, a different case).
        if [ "$tag" != "v${ver}" ] && [ "$tag" != "${ver}" ]; then
            echo "::warning::no release tagged v${ver} or ${ver}; using ${tag} (published ${ts}) for age" >&2
        fi
        printf '%s' "$ts"
        return 0
    done

    [ "$unreachable" = 0 ] || return 3
    return 2
}

# latest_stable_version -> highest-ranked non-prerelease release version on stdout; empty on any
# failure.  Non-zero only when the feed could not be read at all.
#
# This answers a question the digest comparison cannot: `:latest` moving is upstream's decision, so
# a gate that only ever looks at `:latest` cannot tell "upstream has published nothing new" from
# "upstream published something new and did not move the tag". Those look identical from here - a
# fingerprint that matches - and the second one hid a 23-day-old release (2026.7.1-2, a distinct
# digest published 2026-08-04 that `:latest` never moved to) until somebody read the logs by hand.
#
# Prereleases and drafts are dropped: upstream ships betas continuously (2026.8.1-beta.3 and
# friends) and pointing them out every single day is precisely the routine noise this file's header
# refuses to spend a signal on.
#
# Bounded to one page - 100 releases, roughly a year at upstream's cadence - because this only
# reports, and a drift big enough to fall off that window is not one a warning is going to rescue.
latest_stable_version() {
    local url resp tag ver best=""
    url="${GITHUB_API}/repos/${RELEASES_REPO}/releases?per_page=100"

    # Same token-then-anonymous fallback as gh_release_by_tag: the endpoint is public (measured),
    # so GITHUB_TOKEN is rate-limit courtesy and a rejected one must not be the end of the attempt.
    # -f here, unlike gh_release_by_tag, because this one only needs "did I get an array or not" -
    # there is no 404-vs-outage distinction to preserve, since both outcomes produce no warning.
    if [ -n "${GITHUB_TOKEN:-}" ] \
       && resp="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
                      -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url" 2>/dev/null)"; then
        :
    elif ! resp="$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)"; then
        return 1
    fi

    # Strip the `v` the release tags carry and the image labels do not - the same mismatch
    # release_published_at compensates for in the other direction.
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        ver="${tag#v}"
        # Release names are hostile input on the same footing as the image label: this one is only
        # ever printed, but a tag is attacker-influenced text and version_ok is the existing answer.
        version_ok "$ver" || continue
        if [ -z "$best" ] || version_newer "$ver" "$best"; then
            best="$ver"
        fi
    done <<EOF
$(printf '%s' "$resp" | jq -r '.[] | select((.prerelease | not) and (.draft | not)) | .tag_name // empty' 2>/dev/null || true)
EOF

    printf '%s' "$best"
    return 0
}

UP_CANDIDATE="$(docker buildx imagetools inspect "$UPSTREAM" --format '{{.Manifest.Digest}}')"

PUB_RAW="$(docker buildx imagetools inspect "$IMAGE:latest" --raw 2>/dev/null || printf '{}')"
jq_ann() { printf '%s' "$PUB_RAW" | jq -r ".annotations[\"$1\"] // \"\"" 2>/dev/null || printf ''; }
PUBLISHED="$(jq_ann 'io.cookiesncache.inputs')"
UP_PUBLISHED="$(jq_ann 'io.cookiesncache.openclaw.upstream.digest')"
PUB_VER="$(jq_ann 'org.opencontainers.image.version')"

REPO_INPUTS="$(git rev-parse HEAD:Dockerfile HEAD:root HEAD:.dockerignore HEAD:.github/workflows/build.yml | sha256sum | cut -c1-16)"

# Month stamp, computed ONCE here and consumed by both build sites. It is a genuine build input:
# it is passed as a build-arg above the apt layer, so changing it changes the bytes produced.
# Hashing it therefore belongs in the fingerprint rather than being a special case elsewhere -
# the first fingerprint-checking run of each month publishes with freshly installed packages,
# and every later run that month is a no-op again.
APT_EPOCH="$(date -u +%Y-%m)"

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

# There is deliberately no `day -eq 1` FORCE_PUBLISH here any more. The monthly package refresh
# is expressed through APT_EPOCH in the fingerprint instead, which is strictly better: it cannot
# be missed if a scheduled run is dropped (the next run of the month publishes instead), and it
# forces the apt layer to actually re-execute rather than merely forcing a push that a warm
# layer cache could satisfy with months-old packages.

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

    # Cursor-paginated, with a hard cap on the number of REQUESTS.
    #
    # This endpoint does not honour `page`; it is cursor-paginated and silently ignores the
    # parameter. Measured 2026-08-23, asking for page=1,2,3 returned the SAME 100 advisories three
    # times - the three id sets were byte-identical and their union was 100, not 300 - so the gate
    # only ever saw the newest 100 entries (a window of 2026-05-28..2026-06-30) and two of every
    # three requests were wasted. The cursor for the next slice arrives in the Link response
    # header and is opaque: passing after=<ghsa_id> is an HTTP 400, so it cannot be constructed
    # and must be read back from the header.
    #
    # ADV_MAX_PAGES therefore bounds REQUESTS, which is the bound it was always meant to be: at
    # the default of 3 the gate now reads 300 distinct advisories (roughly three months) instead
    # of the same 100 three times. The walk also stops early, on the first response whose Link
    # header carries no rel="next" - the authoritative end-of-feed signal, and unlike a short-page
    # check it is still correct when the final slice happens to hold exactly 100 entries.
    #
    # A bounded window is still sufficient, for a reason worth writing down: an advisory that
    # affects the version we are CURRENTLY SHIPPING is, by definition, newly published, so it sits
    # at the top of this feed. Older advisories cap at older versions and cannot affect a current
    # PUB_VER. The window only matters if the gate stops running for weeks while upstream keeps
    # shipping, and in that case the daily build has already stopped being daily.
    #
    # GITHUB_TOKEN is a rate-limit courtesy only - the endpoint serves another repo's published
    # advisories unauthenticated, which is also the fallback when the token is absent or rejected.
    ADV=""        # advisory JSON array from the most recent request
    ADV_NEXT=""   # cursor for the following request; empty once the feed is exhausted
    # Results come back in ADV/ADV_NEXT rather than on stdout, and the caller must therefore
    # invoke this WITHOUT command substitution: `$(...)` runs the function in a subshell, so the
    # ADV_NEXT it assigns would die with that subshell, every request would re-fetch the first
    # slice, and the defect this rewrite exists to remove would be back - silently.
    adv_fetch_page() { # <cursor> -> sets ADV and ADV_NEXT; non-zero on failure
        local cursor="$1" url resp headers link
        # Rebuilt from GITHUB_API on every request, taking only the cursor from the header. The
        # absolute URL the header offers points at api.github.com by numeric repository id, so
        # following it verbatim would walk straight past a GITHUB_API override after the first
        # request - and would let a response header choose the host we talk to.
        url="${GITHUB_API}/repos/${ADVISORY_REPO}/security-advisories?state=published&per_page=100"
        [ -z "$cursor" ] || url="${url}&after=${cursor}"

        # -fsS matters: without -f, curl exits 0 on an HTTP 403/404 and hands jq a JSON *object*
        # ({"message": "API rate limit exceeded"}) rather than an array, so the fallback would
        # never fire and the object would be parsed as if it were data. (gh_release_by_tag above
        # deliberately omits -f because it needs the status code; the two want opposite things.)
        #
        # -D - prepends the response headers to stdout so the cursor and the advisories it belongs
        # to come from ONE request rather than a second lookup.
        if [ -n "${GITHUB_TOKEN:-}" ] \
           && resp="$(curl -fsS -D - --max-time 20 -H 'Accept: application/vnd.github+json' \
                          -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url" 2>/dev/null)"; then
            :
        elif ! resp="$(curl -fsS -D - --max-time 20 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)"; then
            ADV=""
            ADV_NEXT=""
            return 1
        fi

        # HTTP separates headers from body with a blank line. Normalising CR first makes the split
        # independent of line endings; a bare CR cannot appear inside JSON text - it is escaped as
        # the two characters \r - so stripping it cannot corrupt the body.
        resp="${resp//$'\r'/}"
        headers="${resp%%$'\n\n'*}"
        ADV="${resp#*$'\n\n'}"

        # Link: <...&after=CURSOR>; rel="next", <...&before=CURSOR>; rel="prev"
        #
        # The header NAME is deliberately never matched on, which sidesteps a real trap: HTTP/2
        # lowercases header names, so the live header is `link:` and a `^Link:` match would find
        # nothing. The walk would stop after one request and the gate would quietly go back to
        # reading only the newest 100 advisories - this same bug wearing a different hat, and
        # silent. Keying on the `>;rel="next"` tail is case-proof and specific enough on its own;
        # no other response header carries that shape.
        #
        # Split on "," so the rel="prev" link - which carries a `before=` cursor - cannot be
        # mistaken for the next one, and so the bare `Link` token that
        # access-control-expose-headers contributes to the same split is rejected too. The match
        # is also unanchored on purpose: the header name rides on the FIRST segment
        # (`link:<https://...>`) while later segments begin at `<`, so anchoring at `^<` would
        # find the cursor on every page EXCEPT the first - the one page that always exists.
        #
        # No `head -1` anywhere: under `set -o pipefail` a downstream head can SIGPIPE the
        # producer and fail the substitution. The first match is taken by parameter expansion
        # instead. The cursor is handed back still percent-encoded, exactly as the server sent it.
        link="$(printf '%s' "$headers" | tr -d ' ' | tr ',' '\n' \
                | sed -n 's/.*[?&]after=\([^&>]*\)>;rel="next".*/\1/p' || true)"
        ADV_NEXT="${link%%$'\n'*}"
        return 0
    }

    RANGES=""
    adv_any=false
    adv_cursor=""
    for adv_req in $(seq 1 "${ADV_MAX_PAGES:-3}"); do
        if ! adv_fetch_page "$adv_cursor"; then
            if [ "$adv_any" = false ]; then
                echo "::warning::could not read ${ADVISORY_REPO} security advisories - falling back to the normal cooldown"
            else
                echo "::warning::advisory request ${adv_req} could not be read - checking only the advisories already fetched"
            fi
            break
        fi
        adv_any=true
        adv_cursor="$ADV_NEXT"

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

        # No rel="next" cursor means this was the last slice of the feed.
        [ -n "$adv_cursor" ] || break
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
FAIL_REASON=""
CAND_PUBLISHED=""
# Distinguishes "the age lookup ran and came back empty" from "the age lookup never ran". Both leave
# CAND_AGE empty, and collapsing them in the log cost somebody a three-day investigation into a
# lookup that was working: on the `adopt (unchanged)` path below the lookup is deliberately skipped -
# there is no new digest to soak - yet the log still printed `released unknown, age unknownd`, which
# reads exactly like a failing API call. Only the log consumes this; no decision depends on it.
AGE_CHECKED=false

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
    # the day an outage coincides with a fresh release. Self-correcting and degrades no decision,
    # so it stays a warning rather than joining the exit-non-zero cases below.
    UP_BUILD="$UP_PUBLISHED"
    DECISION="hold (could not inspect candidate - treating as young)"
    echo "::warning::could not inspect ${UPSTREAM_REPO}@${UP_CANDIDATE} - holding until the next run"
elif ! version_ok "$CAND_VER"; then
    # No join key, so no trustworthy age. Note this is where a STRIPPED version label lands too -
    # indistinguishable from an upstream that simply stopped setting it, and both need a human.
    UP_BUILD="$UP_PUBLISHED"
    DECISION="hold (candidate version label missing or unusable)"
    FAIL_REASON="candidate ${UP_CANDIDATE} has no usable org.opencontainers.image.version label (got '${CAND_VER}') - the gate cannot establish a trustworthy age"
elif ! version_newer "$CAND_VER" "$PUB_VER"; then
    UP_BUILD="$UP_PUBLISHED"
    DECISION="hold (candidate ${CAND_VER} does not outrank shipping ${PUB_VER})"
    FAIL_REASON="candidate claims version ${CAND_VER}, which does not outrank the shipping ${PUB_VER} - a downgrade, or a replay of an already-released version, which is what borrowing an old release date looks like"
else
    # Deliberately NO fallback to the image's own `created` in either failure branch below.
    # Falling back to the field this change exists to distrust, in the exact case where the
    # trustworthy source is unavailable, defeats the change - better to stop and be told.
    REL_RC=0
    AGE_CHECKED=true
    CAND_PUBLISHED="$(release_published_at "$CAND_VER")" || REL_RC=$?
    if [ "$REL_RC" = 2 ]; then
        UP_BUILD="$UP_PUBLISHED"
        DECISION="hold (no release matches ${CAND_VER})"
        FAIL_REASON="no ${RELEASES_REPO} release matches candidate version ${CAND_VER} - an image published with no corresponding release is the shape a compromised build takes"
    elif [ "$REL_RC" != 0 ]; then
        UP_BUILD="$UP_PUBLISHED"
        DECISION="hold (releases API unreachable)"
        FAIL_REASON="could not read ${RELEASES_REPO} releases from ${GITHUB_API} - the gate cannot establish a trustworthy age for ${CAND_VER}"
    else
        CAND_AGE="$(age_days "$CAND_PUBLISHED")"
        if [ -z "$CAND_AGE" ]; then
            UP_BUILD="$UP_PUBLISHED"
            DECISION="hold (release date unusable)"
            FAIL_REASON="the ${RELEASES_REPO} release for ${CAND_VER} carries an unusable published_at ('${CAND_PUBLISHED}')"
        elif [ "$CAND_AGE" -lt "$COOLDOWN_DAYS" ]; then
            UP_BUILD="$UP_PUBLISHED"
            DECISION="hold (release is ${CAND_AGE}d old, cooldown ${COOLDOWN_DAYS}d)"
        fi
    fi
fi

# The age clause reports which of three things happened, because they mean different things and the
# reader cannot tell them apart from an empty CAND_AGE. Printing `age unknownd` for all three - a
# literal string where a number belongs - is what made a skipped lookup look like a broken one.
if [ -n "$CAND_AGE" ]; then
    AGE_CLAUSE="released ${CAND_PUBLISHED}, age ${CAND_AGE}d"
elif [ "$AGE_CHECKED" = "true" ]; then
    # Never silent: this branch always coincides with a FAIL_REASON below, which names which of the
    # two failure modes (no matching release / API unreachable) actually occurred.
    AGE_CLAUSE="age lookup failed"
else
    AGE_CLAUSE="age not checked"
fi

# A hold must never be silent: nothing bounds it automatically, so this line is how a persistent
# hold becomes visible. Built once because both the success and the failure path print it.
UPSTREAM_LOG="upstream: candidate=${UP_CANDIDATE} (${CAND_VER:-unknown}, ${AGE_CLAUSE}) published=${UP_PUBLISHED:-none} (${PUB_VER:-unknown}) -> ${DECISION}"

# A2 is accepted risk, so there is no issue-notification channel: a red run is the only signal that
# reaches anyone, and GitHub emails on workflow failure by default. The job is idempotent and runs
# daily, so a failed run costs at most one day of delay.
#
# The diagnostic line goes out FIRST - it is the only context a failure email points at. Nothing is
# written to $GITHUB_OUTPUT: the job fails, every later step is skipped, and that IS the hold.
if [ -n "$FAIL_REASON" ]; then
    echo "::notice::${UPSTREAM_LOG}"
    echo "::error::${FAIL_REASON}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Upstream tag drift
#
# Runs ONLY on `adopt (unchanged)`. That is the one decision that is both silent and open-ended:
# every other path either takes a new digest (drift is moot - we just moved) or holds loudly with a
# red run that already has somebody's attention. The steady state is where a stale `:latest` hides.
#
# This never fails the job and never holds, on any path, which is the whole reason it is allowed to
# exist: per the header, a red run is reserved for "I could not make this decision safely" and is
# never spent on a condition with a safe fallback. Drift changes no decision - what we build is
# still whatever `:latest` resolves to - so it gets a warning and nothing more. Adopting a release
# upstream has not promoted stays a deliberate `adopt` dispatch.
#
# Cost is one request, on no-op runs only.
# ---------------------------------------------------------------------------
if [ "$DECISION" = "adopt (unchanged)" ] && version_ok "$CAND_VER"; then
    DRIFT_VER="$(latest_stable_version 2>/dev/null || true)"
    # version_newer, not a date comparison: upstream's maintenance lines publish out of version
    # order - v2026.6.34 landed 2026-08-08, AFTER v2026.7.1-2 on 2026-08-04 - so "newest by date"
    # would warn every day that we are behind a backport we deliberately outrank. Ranking by
    # version makes that case correctly silent.
    if [ -n "$DRIFT_VER" ] && version_newer "$DRIFT_VER" "$CAND_VER"; then
        echo "::warning::${RELEASES_REPO} has released ${DRIFT_VER}, but ${UPSTREAM} still resolves to ${CAND_VER} (${UP_CANDIDATE}) - upstream has not moved the tag. Dispatch with adopt=true to take it early."
    fi
fi

HASH="$(printf '%s\n%s\n%s\n' "$UP_BUILD" "$REPO_INPUTS" "$APT_EPOCH" | sha256sum | cut -c1-16)"

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
    echo "apt_epoch=$APT_EPOCH"
} >> "$GITHUB_OUTPUT"

echo "::notice::${UPSTREAM_LOG}"
if [ "$PUBLISH" = "true" ]; then
    echo "::notice::publishing: fingerprint ${HASH} (published was '${PUBLISHED:-none}', force_publish=${FORCE_PUBLISH}, force_adopt=${FORCE_ADOPT}), building against ${UP_BUILD}"
else
    echo "::notice::no input changed (fingerprint ${HASH}) - nothing to publish."
fi
