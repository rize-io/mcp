#!/usr/bin/env bash
# Validates that the published artifact files in a Git tree name their
# rize-io/sol source. Everything is read from the exact target tree with
# `git show <rev>:<path>`; the working tree is never consulted.
#
# Usage: check-provenance.sh <push|pull_request> <head-rev> [<base-rev>]
#   head-rev  the tree being validated (the pushed commit or the PR head)
#   base-rev  the previous main head (push) or the PR base; empty/omitted when
#             unknown. Needs full history.
#
# Durable metadata: a root publish-provenance.json, schema_version 1:
#   {
#     "schema_version": 1,
#     "source_repository": "rize-io/sol",
#     "source_sha": "<40 lowercase hex>",
#     "source_pull_request": <positive integer>,
#     "manifest_version": "<must equal manifest.json .version in the same tree>",
#     "source_run_url": "https://github.com/rize-io/sol/actions/runs/<positive integer>"
#   }
# Exactly these keys, these types, these values. When the file exists it is the
# only thing checked: malformed or invalid metadata fails and never falls back
# to commit messages. Once metadata exists in the base or anywhere in the head's
# history, removing it fails. When a base is known and artifact files (anything
# outside .github/ other than the metadata itself) changed, the metadata must
# have changed too, so stale metadata cannot ride along with new content.
#
# Legacy (pre-migration) trees have no metadata. Then the last commit touching
# artifact files must be a publisher commit whose subject (%s) is exactly
# `Publish Rize desktop extension <manifest.json version>` and whose body (%b)
# has a line matching `Mirrored from rize-io/sol@<40 hex>.`. On pull_request this legacy path is allowed only when
# the PR changes nothing outside .github/ (controls-only); artifact changes in a
# PR require the metadata file.
#
# Both paths validate the source-reference format only. They do not prove the
# referenced Sol commit was reviewed or tested, and they are not a cryptographic
# attestation of the published content.
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

# Paths that changed between the base (via merge-base) and the head, excluding
# .github/. Empty output means a controls-only change.
changed_since_base=''
if [ -n "$base" ]; then
  merge_base=$(git merge-base "$base" "$head" 2>/dev/null || true)
  diff_from=${merge_base:-$base}
  changed_since_base=$(git diff --name-only "$diff_from" "$head" -- . ':(exclude).github')
fi
artifact_paths_changed=$(grep -Fxv "$METADATA_PATH" <<<"$changed_since_base" || true)
metadata_changed=false
if grep -Fxq "$METADATA_PATH" <<<"$changed_since_base"; then metadata_changed=true; fi

if tree_has "$head" "$METADATA_PATH"; then
  metadata=$(tree_show "$head" "$METADATA_PATH")
  # Compare against the literal `true` so empty input (no jq output) also fails.
  verdict=$(jq -n --arg repo "$SOURCE_REPOSITORY" --arg manifest_version "$manifest_version" '
    [inputs] | if length != 1 then false else .[0] |
      type == "object"
      and (keys == ["manifest_version", "schema_version", "source_pull_request",
                    "source_repository", "source_run_url", "source_sha"])
      and .schema_version == 1
      and .source_repository == $repo
      and (.source_sha | type == "string" and test("^[0-9a-f]{40}$"))
      and (.source_pull_request | type == "number" and . == floor and . >= 1)
      and (.manifest_version | type == "string" and . == $manifest_version)
      and (.source_run_url | type == "string"
           and test("^https://github\\.com/" + $repo + "/actions/runs/[1-9][0-9]*$"))
    end
  ' <<<"$metadata" 2>/dev/null || true)
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

# No metadata at head. Refuse if it existed before: in the base, or anywhere in
# the head's own history (introduced, then removed).
if [ -n "$base" ] && tree_has "$base" "$METADATA_PATH"; then
  fail "${METADATA_PATH} exists at ${base} but not at ${head}; provenance metadata cannot be removed."
fi
if [ -n "$(git log -1 --format=%H "$head" -- "$METADATA_PATH")" ]; then
  fail "${METADATA_PATH} was introduced in the history of ${head} and is now missing; provenance metadata cannot be removed."
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
