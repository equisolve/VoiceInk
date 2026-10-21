#!/usr/bin/env bash
# Checks for upstream VoiceInk releases newer than the one this fork is based
# on, and for published security advisories, then opens, updates, or closes a
# single tracking issue in this repository.
#
# Usage: scripts/check-upstream-updates.sh [--dry-run]
#
#   --dry-run  Print the issue body and the action the script would take,
#              without creating, editing, commenting on, or closing issues.
#
# Requires gh (authenticated, for example through GH_TOKEN) and jq.
#
# Environment:
#   UPSTREAM_BASE   Release tag to compare against, overriding UPSTREAM_VERSION.
#                   Use it to test the script against an older base.
#   UPSTREAM_REPO   Upstream repository. Default: Beingpax/VoiceInk
#   FORK_REPO       Repository that gets the issue. Default: $GITHUB_REPOSITORY,
#                   else equisolve/VoiceInk
#   ADVISORY_REPOS  Space-separated repositories whose published security
#                   advisories are listed. Default: the upstream repository,
#                   ggml-org/whisper.cpp, and ggml-org/llama.cpp. Dependabot
#                   doesn't cover whisper.cpp because the Makefile builds it
#                   from source. Advisories for the ggml library that
#                   whisper.cpp bundles are published in llama.cpp; some of
#                   those affect only llama.cpp's server, so read each one.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-Beingpax/VoiceInk}"
FORK_REPO="${FORK_REPO:-${GITHUB_REPOSITORY:-equisolve/VoiceInk}}"
ADVISORY_REPOS="${ADVISORY_REPOS:-$UPSTREAM_REPO ggml-org/whisper.cpp ggml-org/llama.cpp}"
LABEL="upstream-update"
TITLE="Upstream VoiceInk updates and security advisories"
SECURITY_PATTERN='security|vulnerab|\bcve\b'

script_dir="$(cd "$(dirname "$0")" && pwd)"
version_file="$script_dir/../UPSTREAM_VERSION"

dry_run=0
case "${1:-}" in
  --dry-run) dry_run=1 ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

base_tag="${UPSTREAM_BASE:-}"
if [ -z "$base_tag" ]; then
  base_tag="$(grep -v '^[[:space:]]*#' "$version_file" | grep -m1 -v '^[[:space:]]*$' | tr -d '[:space:]' || true)"
fi
if [ -z "$base_tag" ]; then
  echo "error: no release tag found in UPSTREAM_VERSION" >&2
  exit 1
fi

# All published (non-draft) upstream releases, oldest first.
releases="$(gh api --paginate "repos/$UPSTREAM_REPO/releases?per_page=100" \
  --jq '.[] | select(.draft | not) | {tag_name, name, published_at, prerelease, html_url, body}' \
  | jq -s 'sort_by(.published_at)')"

base_published="$(jq -r --arg t "$base_tag" '.[] | select(.tag_name == $t) | .published_at' <<<"$releases")"
if [ -z "$base_published" ]; then
  echo "error: UPSTREAM_VERSION names $base_tag, which isn't a published release in $UPSTREAM_REPO" >&2
  exit 1
fi

# Releases published after the base release, newest first.
newer="$(jq --arg d "$base_published" --arg re "$SECURITY_PATTERN" '
  [ .[] | select(.published_at > $d)
    | . + { security: (((.name // "") + "\n" + (.body // "")) | test($re; "i")) } ]
  | reverse' <<<"$releases")"

# Published repository security advisories since the base release.
advisories="[]"
for repo in $ADVISORY_REPOS; do
  found="$(gh api --paginate "repos/$repo/security-advisories?state=published&per_page=100" \
    --jq '.[] | {ghsa_id, cve_id, severity, summary, html_url, published_at}' \
    | jq -s --arg d "$base_published" --arg repo "$repo" \
      '[ .[] | select(.published_at > $d) | . + {repo: $repo} ]')"
  advisories="$(jq -s 'add' <<<"$advisories $found")"
done

release_count="$(jq length <<<"$newer")"
advisory_count="$(jq length <<<"$advisories")"
keys="$(jq -rn --argjson r "$newer" --argjson a "$advisories" \
  '[($r[] | .tag_name), ($a[] | .ghsa_id)] | sort | join(",")')"

# Dates in the issue read as "October 1, 2026".
date_filter='fromdateiso8601 | strftime("%B %d, %Y") | sub(" 0"; " ")'
base_date="$(jq -rn --arg d "$base_published" "\$d | $date_filter")"
today="$(jq -rn "now | todate | $date_filter")"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
{
  echo "This fork is based on upstream VoiceInk [$base_tag](https://github.com/$UPSTREAM_REPO/releases/tag/$base_tag), published $base_date. The tag is recorded in \`UPSTREAM_VERSION\`."
  echo
  echo "## New upstream releases"
  echo
  if [ "$release_count" -eq 0 ]; then
    echo "None."
  else
    jq -r "
      .[] | \"- [\(.tag_name)](\(.html_url))\"
        + (if .prerelease then \" (pre-release)\" else \"\" end)
        + \", published \(.published_at | $date_filter).\"
        + (if .security then \" **Release notes mention security, a vulnerability, or a CVE.** If it fixes a security issue, ship it as soon as it's built and tested.\" else \"\" end)
    " <<<"$newer"
  fi
  echo
  echo "## Security advisories published since $base_tag"
  echo
  echo "Repository advisories for: ${ADVISORY_REPOS// /, }. Advisories in llama.cpp matter when they affect the ggml library that whisper.cpp bundles. Advisories for Swift packages arrive as Dependabot alerts instead."
  echo
  if [ "$advisory_count" -eq 0 ]; then
    echo "None."
  else
    jq -r '
      .[] | "- **\(.repo)** [\(.ghsa_id)](\(.html_url))"
        + (if .cve_id then " (\(.cve_id))" else "" end)
        + ", severity \(.severity // "unknown"): \(.summary)"
    ' <<<"$advisories"
  fi
  echo
  echo "## What to do"
  echo
  echo "Merge the latest upstream release in the monthly update pull request, and set \`UPSTREAM_VERSION\` to its tag. Ship a security fix as soon as it's built and tested. See \"Keeping VoiceInk updated\" in \`BUILDING.md\`."
  echo
  echo "Last checked $today by \`scripts/check-upstream-updates.sh\`."
  echo
  echo "<!-- upstream-check-keys: $keys -->"
} >"$body_file"

echo "Upstream base: $base_tag ($base_date)"
echo "Newer upstream releases: $release_count"
echo "Security advisories since base: $advisory_count"
echo
cat "$body_file"
echo

need_issue=0
if [ "$release_count" -gt 0 ] || [ "$advisory_count" -gt 0 ]; then
  need_issue=1
fi

if ! existing="$(gh issue list -R "$FORK_REPO" --state open --label "$LABEL" \
  --json number --jq '.[0].number // empty' 2>&1)"; then
  if [ "$dry_run" -eq 1 ]; then
    echo "Dry run: can't list issues in $FORK_REPO ($existing). Assuming no open issue."
    existing=""
  else
    echo "error: can't list issues in $FORK_REPO: $existing" >&2
    exit 1
  fi
fi

if [ "$need_issue" -eq 1 ]; then
  if [ -n "$existing" ]; then
    old_keys="$(gh issue view "$existing" -R "$FORK_REPO" --json body --jq .body \
      | sed -n 's/.*<!-- upstream-check-keys: \(.*\) -->.*/\1/p')"
    if [ "$dry_run" -eq 1 ]; then
      echo "Dry run: would update issue #$existing."
      [ "$old_keys" != "$keys" ] && echo "Dry run: would comment that the list changed."
      exit 0
    fi
    gh issue edit "$existing" -R "$FORK_REPO" --body-file "$body_file"
    if [ "$old_keys" != "$keys" ]; then
      gh issue comment "$existing" -R "$FORK_REPO" \
        --body "The list of upstream releases or advisories changed. See the issue description."
    fi
    echo "Updated issue #$existing."
  else
    if [ "$dry_run" -eq 1 ]; then
      echo "Dry run: would open an issue titled \"$TITLE\" with the label $LABEL."
      exit 0
    fi
    gh label create "$LABEL" -R "$FORK_REPO" --color D93F0B \
      --description "New upstream VoiceInk release or security advisory" --force
    gh issue create -R "$FORK_REPO" --title "$TITLE" --label "$LABEL" --body-file "$body_file"
  fi
else
  if [ -n "$existing" ]; then
    if [ "$dry_run" -eq 1 ]; then
      echo "Dry run: would close issue #$existing because the fork is up to date."
      exit 0
    fi
    gh issue close "$existing" -R "$FORK_REPO" \
      --comment "The fork is on the latest upstream release ($base_tag) and no new advisories are published. Closing."
    echo "Closed issue #$existing."
  else
    echo "Up to date. No issue needed."
  fi
fi
