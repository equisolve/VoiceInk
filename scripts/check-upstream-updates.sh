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
#   UPSTREAM_REPO   Upstream repository. Default: Beingpax/VoiceInk. Its
#                   advisories are listed from the base release's date.
#   FORK_REPO       Repository that gets the issue. Default: $GITHUB_REPOSITORY,
#                   else equisolve/VoiceInk
#   WHISPER_ADVISORY_REPOS
#                   Space-separated repositories whose advisories can affect
#                   the whisper.cpp we build. Default: ggml-org/whisper.cpp and
#                   ggml-org/llama.cpp. Dependabot doesn't cover whisper.cpp
#                   because the Makefile builds it from source. Advisories for
#                   the ggml library that whisper.cpp bundles are published in
#                   llama.cpp; some of those affect only llama.cpp's server, so
#                   read each one. These are listed from the date of the
#                   whisper.cpp commit pinned in the Makefile, or all of them
#                   when the Makefile has no pin.
#   MAKEFILE        Makefile to read the whisper.cpp pin from. Default: the
#                   repository's Makefile.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-Beingpax/VoiceInk}"
FORK_REPO="${FORK_REPO:-${GITHUB_REPOSITORY:-equisolve/VoiceInk}}"
WHISPER_REPO="ggml-org/whisper.cpp"
WHISPER_ADVISORY_REPOS="${WHISPER_ADVISORY_REPOS:-$WHISPER_REPO ggml-org/llama.cpp}"
LABEL="upstream-update"
TITLE="Upstream VoiceInk updates and security advisories"
SECURITY_PATTERN='security|vulnerab|\bcve\b'

script_dir="$(cd "$(dirname "$0")" && pwd)"
version_file="$script_dir/../UPSTREAM_VERSION"
makefile="${MAKEFILE:-$script_dir/../Makefile}"

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

# Dates in the issue read as "October 1, 2026".
date_filter='fromdateiso8601 | strftime("%B %d, %Y") | sub(" 0"; " ")'
format_date() { jq -rn --arg d "$1" "\$d | $date_filter"; }

# The whisper.cpp commit the Makefile pins, if any, sets the cutoff for
# whisper.cpp and llama.cpp advisories. Without a pin, the build follows
# whisper.cpp's default branch, so no cutoff is safe and every published
# advisory is listed.
whisper_tag="$(sed -n 's/^WHISPER_CPP_TAG[[:space:]]*:*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$makefile" 2>/dev/null | head -n1 || true)"
whisper_commit="$(sed -n 's/^WHISPER_CPP_COMMIT[[:space:]]*:*=[[:space:]]*\([0-9a-f]\{40\}\).*/\1/p' "$makefile" 2>/dev/null | head -n1 || true)"
if [ -n "$whisper_commit" ]; then
  whisper_cutoff="$(gh api "repos/$WHISPER_REPO/commits/$whisper_commit" --jq '.commit.committer.date')"
  whisper_cutoff_text="published after the whisper.cpp commit the Makefile pins (${whisper_tag:-untagged}, \`$whisper_commit\`, committed $(format_date "$whisper_cutoff"))"
else
  whisper_cutoff="1970-01-01T00:00:00Z"
  whisper_cutoff_text="all published advisories, because the Makefile doesn't pin a whisper.cpp commit (no \`WHISPER_CPP_COMMIT\`)"
fi

# Published repository security advisories for one repository after a cutoff.
advisories_since() {
  gh api --paginate "repos/$1/security-advisories?state=published&per_page=100" \
    --jq '.[] | {ghsa_id, cve_id, severity, summary, html_url, published_at}' \
    | jq -s --arg d "$2" --arg repo "$1" \
      '[ .[] | select(.published_at > $d) | . + {repo: $repo} ] | sort_by(.published_at) | reverse'
}

upstream_advisories="$(advisories_since "$UPSTREAM_REPO" "$base_published")"
whisper_advisories="[]"
for repo in $WHISPER_ADVISORY_REPOS; do
  found="$(advisories_since "$repo" "$whisper_cutoff")"
  whisper_advisories="$(jq -s 'add' <<<"$whisper_advisories $found")"
done

release_count="$(jq length <<<"$newer")"
upstream_advisory_count="$(jq length <<<"$upstream_advisories")"
whisper_advisory_count="$(jq length <<<"$whisper_advisories")"
advisory_count=$((upstream_advisory_count + whisper_advisory_count))
keys="$(jq -rn --argjson r "$newer" --argjson a "$upstream_advisories" --argjson w "$whisper_advisories" \
  '[($r[] | .tag_name), ($a[], $w[] | .ghsa_id)] | unique | join(",")')"

base_date="$(format_date "$base_published")"
today="$(jq -rn "now | todate | $date_filter")"

# Text from other repositories goes in code spans, so @mentions don't notify
# anyone and Markdown links don't render.
# shellcheck disable=SC2016  # Backticks here are jq string content.
safe_filter='def safe: tostring | gsub("[\r\n]+"; " ") | gsub("`"; "'"'"'") | "`" + . + "`";'
advisory_lines="$safe_filter"'
  .[] | "- \(.repo): [\(.ghsa_id | safe)](https://github.com/\(.repo)/security/advisories/\(.ghsa_id | @uri))"
    + (if .cve_id then " (\(.cve_id | safe))" else "" end)
    + ", severity \(.severity // "unknown" | safe), published \(.published_at | '"$date_filter"'): \(.summary // "" | safe)"'

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
    jq -r "$safe_filter"'
      .[] | "- \(.tag_name | safe) ([release notes](https://github.com/'"$UPSTREAM_REPO"'/releases/tag/\(.tag_name | @uri)))"
        + (if .prerelease then " (pre-release)" else "" end)
        + ", published \(.published_at | '"$date_filter"')."
        + (if .security then " **Release notes mention security, a vulnerability, or a CVE.** If it fixes a security issue, ship it as soon as it is built and tested." else "" end)
    ' <<<"$newer"
  fi
  echo
  echo "## Upstream VoiceInk security advisories"
  echo
  echo "Advisories in $UPSTREAM_REPO published after $base_tag."
  echo
  if [ "$upstream_advisory_count" -eq 0 ]; then
    echo "None."
  else
    jq -r "$advisory_lines" <<<"$upstream_advisories"
  fi
  echo
  echo "## whisper.cpp security advisories"
  echo
  echo "Advisories in ${WHISPER_ADVISORY_REPOS// /, }: $whisper_cutoff_text. Advisories in llama.cpp matter when they affect the ggml library that whisper.cpp bundles; some affect only llama.cpp's server. Advisories for Swift packages arrive as Dependabot alerts instead."
  echo
  if [ "$whisper_advisory_count" -eq 0 ]; then
    echo "None."
  else
    jq -r "$advisory_lines" <<<"$whisper_advisories"
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
echo "Upstream VoiceInk advisories since base: $upstream_advisory_count"
echo "whisper.cpp advisories: $whisper_advisory_count"
echo
cat "$body_file"
echo

need_issue=0
if [ "$release_count" -gt 0 ] || [ "$advisory_count" -gt 0 ]; then
  need_issue=1
fi

# Find the open tracking issue by its label, or by its exact title in case
# someone removed the label.
existing=""
has_label=0
if ! open_issues="$(gh issue list -R "$FORK_REPO" --state open --limit 100 \
  --search "\"$TITLE\" in:title" --json number,title,labels 2>&1)"; then
  echo "error: can't list issues in $FORK_REPO: $open_issues" >&2
  exit 1
fi
if ! labeled="$(gh issue list -R "$FORK_REPO" --state open --limit 1 --label "$LABEL" \
  --json number,title,labels 2>&1)"; then
  echo "error: can't list issues in $FORK_REPO: $labeled" >&2
  exit 1
fi
match="$(jq -rn --argjson a "$labeled" --argjson b "$open_issues" --arg t "$TITLE" --arg l "$LABEL" '
  ($a + [ $b[] | select(.title == $t) ]) | sort_by(.number) | first
  | if . == null then "" else "\(.number) \([.labels[].name] | index($l) != null)" end')"
if [ -n "$match" ]; then
  existing="${match%% *}"
  [ "${match#* }" = "true" ] && has_label=1
fi

ensure_label() {
  gh label create "$LABEL" -R "$FORK_REPO" --color D93F0B \
    --description "New upstream VoiceInk release or security advisory" --force
}

if [ "$need_issue" -eq 1 ]; then
  if [ -n "$existing" ]; then
    old_keys="$(gh issue view "$existing" -R "$FORK_REPO" --json body --jq .body \
      | sed -n 's/.*<!-- upstream-check-keys: \(.*\) -->.*/\1/p')"
    if [ "$dry_run" -eq 1 ]; then
      echo "Dry run: would update issue #$existing."
      if [ "$has_label" -eq 0 ]; then echo "Dry run: would add the label $LABEL to issue #$existing."; fi
      if [ "$old_keys" != "$keys" ]; then echo "Dry run: would comment that the list changed."; fi
      exit 0
    fi
    gh issue edit "$existing" -R "$FORK_REPO" --body-file "$body_file"
    if [ "$has_label" -eq 0 ]; then
      ensure_label
      gh issue edit "$existing" -R "$FORK_REPO" --add-label "$LABEL"
    fi
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
    ensure_label
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
