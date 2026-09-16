#!/usr/bin/env bash
# Fixture tests for check-provenance.sh. Builds throwaway Git repositories that
# model the mirror's histories (legacy publisher commits, controls-only PRs,
# publish-provenance.json under merge/squash/rebase, invalid and removed
# metadata) and runs the real validator against them. Needs git and jq.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
VALIDATOR=$SCRIPT_DIR/check-provenance.sh
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

export GITHUB_STEP_SUMMARY=$TMP_ROOT/summary
export GIT_AUTHOR_NAME='Provenance Test'
export GIT_AUTHOR_EMAIL='provenance@example.com'
export GIT_COMMITTER_NAME='Provenance Test'
export GIT_COMMITTER_EMAIL='provenance@example.com'
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
: >"$GITHUB_STEP_SUMMARY"

SOURCE_A=$(printf '%040d' 0 | tr '0' 'a')
SOURCE_B=$(printf '%040d' 0 | tr '0' 'b')
ZERO_BASE=$(printf '%040d' 0)
FAILURES=0
SCENARIOS=0
CURRENT_REPO=

new_repo() {
  local name=$1

  CURRENT_REPO=$TMP_ROOT/$name
  mkdir -p "$CURRENT_REPO"
  git init -q -b main "$CURRENT_REPO"
  mkdir -p "$CURRENT_REPO/server"
  printf '%s\n' '{"version":"1.0.0","name":"Fixture"}' >"$CURRENT_REPO/manifest.json"
  printf '%s\n' 'export default "fixture";' >"$CURRENT_REPO/server/index.js"
  printf '%s\n' '# Fixture' >"$CURRENT_REPO/README.md"
  git -C "$CURRENT_REPO" add manifest.json server/index.js README.md
  git -C "$CURRENT_REPO" commit -qm 'Initial fixture'
}

publisher_commit() {
  local version=$1
  local source_sha=$2

  printf '%s\n' "{\"version\":\"$version\",\"name\":\"Fixture\"}" >"$CURRENT_REPO/manifest.json"
  printf '%s\n' "export default \"fixture-$version\";" >"$CURRENT_REPO/server/index.js"
  git -C "$CURRENT_REPO" add manifest.json server/index.js
  git -C "$CURRENT_REPO" commit -qm \
    "Publish Rize desktop extension $version" \
    -m "Mirrored from rize-io/sol@$source_sha."
}

write_metadata() {
  local version=$1
  local source_sha=$2

  jq -n \
    --arg source_sha "$source_sha" \
    --arg manifest_version "$version" \
    '{
      schema_version: 1,
      source_repository: "rize-io/sol",
      source_sha: $source_sha,
      source_pull_request: 16002,
      manifest_version: $manifest_version,
      source_run_url: "https://github.com/rize-io/sol/actions/runs/123456789"
    }' >"$CURRENT_REPO/publish-provenance.json"
}

expect_pass() {
  local name=$1
  shift
  local stdout_file=$TMP_ROOT/validator.stdout
  local stderr_file=$TMP_ROOT/validator.stderr

  SCENARIOS=$((SCENARIOS + 1))
  if (cd -- "$CURRENT_REPO" && "$VALIDATOR" "$@") >"$stdout_file" 2>"$stderr_file"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (expected pass)\n' "$name"
    cat "$stdout_file" "$stderr_file"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_fail() {
  local name=$1
  local substring=$2
  shift 2
  local stdout_file=$TMP_ROOT/validator.stdout
  local stderr_file=$TMP_ROOT/validator.stderr

  SCENARIOS=$((SCENARIOS + 1))
  if (cd -- "$CURRENT_REPO" && "$VALIDATOR" "$@") >"$stdout_file" 2>"$stderr_file"; then
    printf 'FAIL: %s (expected failure)\n' "$name"
    cat "$stdout_file" "$stderr_file"
    FAILURES=$((FAILURES + 1))
  elif grep -Fq -- "$substring" "$stderr_file"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (stderr did not contain %s)\n' "$name" "$substring"
    cat "$stdout_file" "$stderr_file"
    FAILURES=$((FAILURES + 1))
  fi
}

setup_valid_metadata_main() {
  local name=$1

  new_repo "$name"
  publisher_commit 1.0.0 "$SOURCE_A"
  write_metadata 1.0.0 "$SOURCE_A"
  git -C "$CURRENT_REPO" add publish-provenance.json
  git -C "$CURRENT_REPO" commit -qm 'Add provenance metadata'
}

setup_metadata_pr() {
  local name=$1

  new_repo "$name"
  publisher_commit 1.0.0 "$SOURCE_A"
  OLD_MAIN=$(git -C "$CURRENT_REPO" rev-parse HEAD)
  git -C "$CURRENT_REPO" switch -q -c sync
  printf '%s\n' '{"version":"1.1.0","name":"Fixture"}' >"$CURRENT_REPO/manifest.json"
  printf '%s\n' 'export default "fixture-1.1.0";' >"$CURRENT_REPO/server/index.js"
  write_metadata 1.1.0 "$SOURCE_B"
  git -C "$CURRENT_REPO" add manifest.json server/index.js publish-provenance.json
  git -C "$CURRENT_REPO" commit -qm 'Sync bundle (#7)'
}

invalid_metadata_case() {
  local name=$1
  local content=$2

  new_repo "invalid-$name"
  publisher_commit 1.0.0 "$SOURCE_A"
  printf '%s' "$content" >"$CURRENT_REPO/publish-provenance.json"
  git -C "$CURRENT_REPO" add publish-provenance.json
  git -C "$CURRENT_REPO" commit -qm \
    'Publish Rize desktop extension 1.0.0' \
    -m "Mirrored from rize-io/sol@$SOURCE_A."
  expect_fail "invalid metadata: $name (push)" \
    'not valid schema_version 1' push HEAD
  if [ "$name" = malformed-json ]; then
    expect_fail "invalid metadata: $name (pull request)" \
      'not valid schema_version 1' pull_request HEAD main
  fi
}

new_repo legacy-two-publishers
publisher_commit 1.0.0 "$SOURCE_A"
FIRST_PUBLISHER=$(git -C "$CURRENT_REPO" rev-parse HEAD)
publisher_commit 1.1.0 "$SOURCE_B"
expect_pass 'legacy push at first publisher commit' push HEAD "$FIRST_PUBLISHER"
expect_pass 'legacy push without base' push HEAD

new_repo controls-pr
publisher_commit 1.0.0 "$SOURCE_A"
OLD_MAIN=$(git -C "$CURRENT_REPO" rev-parse HEAD)
git -C "$CURRENT_REPO" switch -q -c controls
mkdir -p "$CURRENT_REPO/.github/workflows"
printf '%s\n' 'name: fixture' >"$CURRENT_REPO/.github/workflows/x.yml"
git -C "$CURRENT_REPO" add .github/workflows/x.yml
git -C "$CURRENT_REPO" commit -qm 'Tighten checks'
expect_pass 'legacy controls-only pull request' pull_request controls main
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --no-ff -q controls -m 'Merge controls'
expect_pass 'legacy controls-only push after merge' push main "$OLD_MAIN"

new_repo artifact-pr
publisher_commit 1.0.0 "$SOURCE_A"
git -C "$CURRENT_REPO" switch -q -c artifact
printf '%s\n' 'export default "ordinary-change";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add server/index.js
git -C "$CURRENT_REPO" commit -qm 'Ordinary artifact change'
expect_fail 'artifact pull request without metadata' \
  'without publish-provenance.json' pull_request artifact main

new_repo nonpublisher-subject
publisher_commit 1.0.0 "$SOURCE_A"
printf '%s\n' 'export default "tweak";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add server/index.js
git -C "$CURRENT_REPO" commit -qm 'Tweak manifest' -m "Mirrored from rize-io/sol@$SOURCE_A."
expect_fail 'non-publisher subject' 'subject is not' push HEAD

new_repo body-only
publisher_commit 1.0.0 "$SOURCE_A"
printf '%s\n' 'export default "body-only";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add server/index.js
git -C "$CURRENT_REPO" commit -qm Chore \
  -m $'Publish Rize desktop extension 1.0.0\n\nMirrored from rize-io/sol@'"$SOURCE_A."
expect_fail 'publisher text in body does not satisfy subject' 'subject is not' push HEAD

new_repo missing-body-reference
publisher_commit 1.0.0 "$SOURCE_A"
printf '%s\n' 'export default "missing-body";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add server/index.js
git -C "$CURRENT_REPO" commit -qm 'Publish Rize desktop extension 1.0.0' -m 'No source reference'
expect_fail 'publisher subject without source body' 'body does not reference' push HEAD

new_repo wrong-manifest-version
publisher_commit 1.0.0 "$SOURCE_A"
printf '%s\n' '{"version":"1.0.0","name":"Fixture"}' >"$CURRENT_REPO/manifest.json"
printf '%s\n' 'export default "wrong-version";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add manifest.json server/index.js
git -C "$CURRENT_REPO" commit -qm \
  'Publish Rize desktop extension 1.0.1' \
  -m "Mirrored from rize-io/sol@$SOURCE_A."
expect_fail 'publisher subject version differs from manifest' 'subject is not' push HEAD

new_repo pull-request-without-base
publisher_commit 1.0.0 "$SOURCE_A"
expect_fail 'pull request without base revision' 'requires the PR base' pull_request HEAD

setup_metadata_pr metadata-merge
expect_pass 'metadata artifact pull request' pull_request sync main
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --no-ff -q sync -m 'Merge pull request #7 from x/y'
expect_pass 'metadata no-ff merge push with base' push main "$OLD_MAIN"
expect_pass 'metadata no-ff merge push without base' push main

setup_metadata_pr metadata-squash
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --squash -q sync >/dev/null
git -C "$CURRENT_REPO" commit -qm 'Sync bundle (#7)'
expect_pass 'metadata squash merge push with base' push main "$OLD_MAIN"
expect_pass 'metadata squash merge push without base' push main

setup_metadata_pr metadata-rebase
git -C "$CURRENT_REPO" switch -q main
mkdir -p "$CURRENT_REPO/.github"
printf '%s\n' 'rebase fixture control' >"$CURRENT_REPO/.github/rebase"
git -C "$CURRENT_REPO" add .github/rebase
git -C "$CURRENT_REPO" commit -qm 'Add control before rebase'
git -C "$CURRENT_REPO" switch -q sync
git -C "$CURRENT_REPO" rebase -q main
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --ff-only -q sync
expect_pass 'metadata rebase fast-forward push with base' push main "$OLD_MAIN"
expect_pass 'metadata rebase fast-forward push without base' push main

setup_valid_metadata_main controls-on-metadata
OLD_METADATA_MAIN=$(git -C "$CURRENT_REPO" rev-parse HEAD)
git -C "$CURRENT_REPO" switch -q -c metadata-controls
mkdir -p "$CURRENT_REPO/.github"
printf '%s\n' 'control-only change' >"$CURRENT_REPO/.github/foo"
git -C "$CURRENT_REPO" add .github/foo
git -C "$CURRENT_REPO" commit -qm 'Tighten checks'
expect_pass 'metadata controls-only pull request' pull_request metadata-controls main
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --no-ff -q metadata-controls -m 'Merge controls'
expect_pass 'metadata controls-only push after merge' push main "$OLD_METADATA_MAIN"

invalid_metadata_case malformed-json '{ not json'
invalid_metadata_case empty ''
invalid_metadata_case json-array '[]'
invalid_metadata_case extra-key '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789","extra":1}'
invalid_metadata_case missing-run-url '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0"}'
invalid_metadata_case schema-version-2 '{"schema_version":2,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case schema-version-string '{"schema_version":"1","source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case wrong-source-repository '{"schema_version":1,"source_repository":"rize-io/mcp","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case uppercase-source-sha '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"${SOURCE_A^^}"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case short-source-sha '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"${SOURCE_A:1}"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case zero-source-pr '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":0,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case string-source-pr '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":"16002","manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case fractional-source-pr '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":1.5,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case wrong-manifest-version '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.1","source_run_url":"https://github.com/rize-io/sol/actions/runs/123456789"}'
invalid_metadata_case http-run-url '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"http://github.com/rize-io/sol/actions/runs/1"}'
invalid_metadata_case wrong-run-repository '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/mcp/actions/runs/1"}'
invalid_metadata_case trailing-run-slash '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/1/"}'
invalid_metadata_case nonnumeric-run-id '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/abc"}'
invalid_metadata_case query-run-url '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://github.com/rize-io/sol/actions/runs/1?x=1"}'
invalid_metadata_case evil-run-url '{"schema_version":1,"source_repository":"rize-io/sol","source_sha":"'"$SOURCE_A"'","source_pull_request":16002,"manifest_version":"1.0.0","source_run_url":"https://evil.example/github.com/rize-io/sol/actions/runs/1"}'

setup_valid_metadata_main removal
VALID_METADATA_MAIN=$(git -C "$CURRENT_REPO" rev-parse HEAD)
git -C "$CURRENT_REPO" switch -q -c remove-metadata
git -C "$CURRENT_REPO" rm -q publish-provenance.json
git -C "$CURRENT_REPO" commit -qm \
  'Publish Rize desktop extension 1.0.0' \
  -m "Mirrored from rize-io/sol@$SOURCE_A."
expect_fail 'metadata removal pull request' 'cannot be removed' pull_request remove-metadata main
git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" merge --no-ff -q remove-metadata -m 'Merge removal'
expect_fail 'metadata removal push with base' 'cannot be removed' push main "$VALID_METADATA_MAIN"
expect_fail 'metadata removal push without base' 'cannot be removed' push main

new_repo stale-branch
publisher_commit 1.0.0 "$SOURCE_A"
git -C "$CURRENT_REPO" switch -q -c stale
git -C "$CURRENT_REPO" switch -q main
write_metadata 1.0.0 "$SOURCE_A"
git -C "$CURRENT_REPO" add publish-provenance.json
git -C "$CURRENT_REPO" commit -qm 'Add provenance metadata'
expect_fail 'stale branch before metadata was added' 'cannot be removed' pull_request stale main

setup_valid_metadata_main stale-metadata
git -C "$CURRENT_REPO" switch -q -c stale-artifact
printf '%s\n' 'export default "stale-artifact";' >"$CURRENT_REPO/server/index.js"
git -C "$CURRENT_REPO" add server/index.js
git -C "$CURRENT_REPO" commit -qm 'Change artifact without metadata'
expect_fail 'artifact change with stale metadata' 'did not' pull_request stale-artifact main

git -C "$CURRENT_REPO" switch -q main
git -C "$CURRENT_REPO" switch -q -c changed-metadata
printf '%s\n' 'export default "changed-with-metadata";' >"$CURRENT_REPO/server/index.js"
write_metadata 1.0.0 "$SOURCE_B"
git -C "$CURRENT_REPO" add server/index.js publish-provenance.json
git -C "$CURRENT_REPO" commit -qm 'Refresh artifact provenance'
expect_pass 'artifact and metadata changed together' pull_request changed-metadata main

setup_valid_metadata_main working-tree-valid
printf '%s\n' '{ broken' >"$CURRENT_REPO/publish-provenance.json"
expect_pass 'working tree metadata is ignored for valid ref' push HEAD

new_repo working-tree-invalid
publisher_commit 1.0.0 "$SOURCE_A"
printf '%s\n' '{ broken' >"$CURRENT_REPO/publish-provenance.json"
git -C "$CURRENT_REPO" add publish-provenance.json
git -C "$CURRENT_REPO" commit -qm 'Invalid metadata'
write_metadata 1.0.0 "$SOURCE_A"
expect_fail 'working tree fix is ignored for invalid ref' \
  'not valid schema_version 1' push HEAD

new_repo invalid-inputs
publisher_commit 1.0.0 "$SOURCE_A"
expect_fail 'unresolvable head revision' 'Cannot resolve' push does-not-exist
expect_fail 'invalid event name' 'Usage' deploy HEAD

new_repo zero-base
publisher_commit 1.0.0 "$SOURCE_A"
expect_pass 'GitHub branch-creation zero base' push HEAD "$ZERO_BASE"

printf 'Provenance tests: %d run, %d failed.\n' "$SCENARIOS" "$FAILURES"
if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
