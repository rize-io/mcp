#!/usr/bin/env bash
# Validates that the published artifact files in a Git tree name their
# rize-io/sol source, reading only from the target tree (`git show <rev>:<path>`).
#
# Usage: check-provenance.sh <push|pull_request> <head-rev> [<base-rev>]
#
# With a root publish-provenance.json (schema_version 1) at head, that file is
# strictly validated and commit messages are ignored. Once the file exists in the
# base or anywhere in either history, its absence fails. Without it, the last
# commit touching artifact files (outside .github/) must be a publisher commit:
# subject `Publish Rize desktop extension <manifest version>`, body line
# `Mirrored from rize-io/sol@<40 hex>.`; on pull_request only controls-only
# changes may use this legacy path.
#
# Both paths check the source-reference format only: not proof the source was
# reviewed or tested, and not a cryptographic attestation of content.
set -euo pipefail

METADATA_PATH=publish-provenance.json
SOURCE_REPOSITORY=rize-io/sol

event=${1:-}
head_arg=${2:-}
base_arg=${3:-}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

fail() {
  echo "$*" >&2
  exit 1
}

case "$event" in
  push|pull_request) ;;
  *) fail "Usage: check-provenance.sh <push|pull_request> <head-rev> [<base-rev>]" ;;
esac
[ -n "$head_arg" ] || fail "Usage: check-provenance.sh <push|pull_request> <head-rev> [<base-rev>]"

resolve() {
  git rev-parse --verify --quiet --end-of-options "${1}^{commit}" \
    || fail "Cannot resolve ${1} to a commit."
}

head=$(resolve "$head_arg")
base=''
if [ -n "$base_arg" ] && ! [[ "$base_arg" =~ ^0{40}$ ]]; then
  base=$(resolve "$base_arg")
fi

tree_has() { git cat-file -e "${1}:${2}" 2>/dev/null; }
tree_show() { git show "${1}:${2}"; }

manifest_version=$(tree_show "$head" manifest.json | jq -er '.version | select(type == "string")') \
  || fail "manifest.json at ${head} has no string .version."

# Paths changed between merge-base(base, head) and head, excluding .github/.
changed_since_base=''
diff_from=''
if [ -n "$base" ]; then
  if merge_base=$(git merge-base "$base" "$head"); then
    diff_from=$merge_base
  else
    status=$?
    [ "$status" -eq 1 ] || fail "git merge-base failed with status ${status}."
    diff_from=$base
  fi
  changed_since_base=$(git diff --name-only "$diff_from" "$head" -- . ':(exclude).github')
fi
artifact_paths_changed=''
metadata_changed=false
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ "$path" = "$METADATA_PATH" ]; then
    metadata_changed=true
  else
    artifact_paths_changed+="${path}"$'\n'
  fi
done <<<"$changed_since_base"

if tree_has "$head" "$METADATA_PATH"; then
  metadata=$(tree_show "$head" "$METADATA_PATH")
  # jq prints exactly one `true` for valid metadata; empty input prints nothing.
  if ! verdict=$(jq -n --arg repo "$SOURCE_REPOSITORY" --arg manifest_version "$manifest_version" '
    [inputs] | if length != 1 then false else .[0] |
      type == "object"
      and (keys == ["manifest_version", "schema_version", "source_pull_request",
                    "source_repository", "source_run_url", "source_sha"])
      and .schema_version == 1
      and .source_repository == $repo
      and (.source_sha | type == "string" and test("\\A[0-9a-f]{40}\\z"))
      and (.source_pull_request | type == "number" and . == floor and . >= 1)
      and (.manifest_version | type == "string" and . == $manifest_version)
      and (.source_run_url | type == "string"
           and test("\\Ahttps://github\\.com/" + $repo + "/actions/runs/[1-9][0-9]*\\z"))
    end
  ' <<<"$metadata" 2>&1); then
    fail "${METADATA_PATH} at ${head} is not valid schema_version 1 provenance: ${verdict}"
  fi
  [ "$verdict" = true ] \
    || fail "${METADATA_PATH} at ${head} is not valid schema_version 1 provenance for manifest ${manifest_version}."

  if [ -n "$artifact_paths_changed" ] && [ "$metadata_changed" = false ]; then
    fail "Artifact files changed since ${diff_from} but ${METADATA_PATH} did not; regenerate the provenance metadata with the published content."
  fi

  source_sha=$(jq -r '.source_sha' <<<"$metadata")
  source_pr=$(jq -r '.source_pull_request' <<<"$metadata")
  source_run_url=$(jq -r '.source_run_url' <<<"$metadata")
  {
    echo '## Mirror provenance'
    printf 'Head: %s\n' "$head"
    printf 'Metadata: %s (schema_version 1)\n' "$METADATA_PATH"
    printf 'Source: %s@%s (PR #%s)\n' "$SOURCE_REPOSITORY" "$source_sha" "$source_pr"
    printf 'Publisher run: %s\n' "$source_run_url"
    echo 'Format check of the source reference only; not proof of an approved source or an attestation of content.'
  } >> "$summary"
  printf 'Provenance OK: %s names %s@%s (PR #%s).\n' "$head" "$SOURCE_REPOSITORY" "$source_sha" "$source_pr"
  exit 0
fi

# No metadata at head. Refuse if it existed before: in the base tree, or in any
# commit reachable from head or base (--full-history so a merge that dropped the
# file does not hide the parent that introduced it).
if [ -n "$base" ] && tree_has "$base" "$METADATA_PATH"; then
  fail "${METADATA_PATH} exists at ${base} but not at ${head}; provenance metadata cannot be removed."
fi
introduced=$(git log --full-history -1 --format=%H "$head" ${base:+"$base"} -- "$METADATA_PATH")
if [ -n "$introduced" ]; then
  fail "${METADATA_PATH} was introduced in reachable history (${introduced}) and is missing at ${head}; provenance metadata cannot be removed."
fi

if [ "$event" = pull_request ]; then
  [ -n "$base" ] || fail "pull_request validation requires the PR base revision."
  if [ -n "$artifact_paths_changed" ]; then
    fail "This pull request changes published artifact files without ${METADATA_PATH}; artifact changes require schema_version 1 provenance metadata."
  fi
fi

artifact_commit=$(git log -1 --format=%H "$head" -- . ':(exclude).github')
[ -n "$artifact_commit" ] || fail "No commit touching published artifact files is reachable from ${head}."

subject=$(git log -1 --format=%s "$artifact_commit")
body=$(git log -1 --format=%b "$artifact_commit")
if [ "$subject" != "Publish Rize desktop extension ${manifest_version}" ]; then
  fail "Artifact commit ${artifact_commit} subject is not 'Publish Rize desktop extension ${manifest_version}' and no ${METADATA_PATH} is present."
fi
if ! grep -Eq '^Mirrored from rize-io/sol@[0-9a-f]{40}\.$' <<<"$body"; then
  fail "Artifact commit ${artifact_commit} body does not reference a rize-io/sol source commit."
fi

if [ "$head" = "$artifact_commit" ]; then
  scope="this ${event}"
else
  scope="last artifact change; ${event} touched only .github/"
fi
{
  echo '## Mirror provenance'
  printf 'Head: %s\n' "$head"
  printf 'Artifact commit: %s (%s)\n' "$artifact_commit" "$scope"
  echo 'Metadata: none (legacy commit-message check; publisher migration pending)'
  grep -E '^Mirrored from rize-io/sol@' <<<"$body"
  echo 'Format check of the source reference only; not proof of an approved source or an attestation of content.'
} >> "$summary"
echo "Provenance OK (legacy) for ${artifact_commit} (${scope})."
