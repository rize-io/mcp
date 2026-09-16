#!/usr/bin/env bash
# Checks that the most recent commit touching published artifact files (anything
# outside .github/) is a publisher commit that names its rize-io/sol source.
# This validates the source-reference format only; it is not cryptographic proof
# that the referenced Sol commit was reviewed or tested.
#
# Usage: check-provenance.sh [<ref>]   (defaults to HEAD; needs full history)
set -euo pipefail

ref=${1:-HEAD}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

artifact_commit=$(git log -1 --format=%H "$ref" -- . ':(exclude).github')
if [ -z "$artifact_commit" ]; then
  echo "No commit touching published artifact files is reachable from ${ref}." >&2
  exit 1
fi

body=$(git log -1 --format=%B "$artifact_commit")
version=$(git show "${artifact_commit}:manifest.json" | jq -r '.version')

if ! grep -Eq '^Mirrored from rize-io/sol@[0-9a-f]{40}\.$' <<<"$body"; then
  echo "Artifact commit ${artifact_commit} does not reference a rize-io/sol source commit." >&2
  exit 1
fi
if ! grep -Fq "Publish Rize desktop extension ${version}" <<<"$body"; then
  echo "Artifact commit ${artifact_commit} subject does not match manifest version ${version}." >&2
  exit 1
fi

if [ "$(git rev-parse "$ref")" = "$artifact_commit" ]; then
  scope="this push"
else
  scope="last artifact change; this push touched only .github/"
fi
{
  echo '## Mirror provenance'
  echo "Artifact commit: ${artifact_commit} (${scope})"
  grep -E '^Mirrored from rize-io/sol@' <<<"$body"
  echo 'Format check of the source reference only; not proof of an approved source.'
} >> "$summary"
echo "Provenance OK for ${artifact_commit} (${scope})."
