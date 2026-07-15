#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_repository=$(cd -- "$script_directory/.." && pwd -P)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-preflight-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "preflight-test: $*" >&2
  exit 1
}

repository="$temporary_directory/repository"
mkdir "$repository"
cp -R "$source_repository/." "$repository/"
rm -rf -- "$repository/.git" "$repository/.bench"

git -C "$repository" init -q
git -C "$repository" config user.name 'Preflight Test'
git -C "$repository" config user.email 'preflight@example.invalid'
git -C "$repository" add --all
git -C "$repository" commit -qm 'baseline'
base_commit=$(git -C "$repository" rev-parse HEAD)

printf '\n// Candidate preflight fixture.\n' >>"$repository/internal/analyzer/engine.go"
cp "$repository/scripts/testdata/check-protected/valid_optimization.md" "$repository/OPTIMIZATION.md"
git -C "$repository" add -- internal/analyzer/engine.go OPTIMIZATION.md
git -C "$repository" commit -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)

(cd "$repository" && GOCACHE="$temporary_directory/go-cache" bash scripts/preflight.sh "$base_commit") >/dev/null

set +e
missing_base_output=$(cd "$repository" && GOCACHE="$temporary_directory/go-cache" \
  bash scripts/preflight.sh 0000000000000000000000000000000000000000 2>&1)
missing_base_status=$?
set -e
[[ $missing_base_status -ne 0 ]] || fail 'missing base commit unexpectedly passed'
[[ $missing_base_output == *'cannot resolve preflight base ref'* ]] || fail "missing base reported an unexpected error: $missing_base_output"

# Leave the worktree dirty. Every branch-targeting spelling must invoke the
# preflight and therefore reject it; tag-only and deletion pushes must skip it.
printf '\ndirty pre-push fixture\n' >>"$repository/README.md"

expect_hook_rejects_dirty() {
  local label=$1
  local local_ref=$2
  local output
  local status

  set +e
  output=$(printf '%s %s %s %s\n' \
    "$local_ref" "$candidate_commit" refs/heads/candidate 0000000000000000000000000000000000000000 | \
    (cd "$repository" && STREAMLENS_BASE_REF="$base_commit" bash .githooks/pre-push origin) 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$label bypassed the preflight"
  [[ $output == *'preflight requires a clean worktree'* ]] || fail "$label reported an unexpected error: $output"
}

expect_hook_rejects_dirty 'explicit branch ref' refs/heads/candidate
expect_hook_rejects_dirty 'HEAD refspec' HEAD
expect_hook_rejects_dirty 'raw SHA refspec' "$candidate_commit"
expect_hook_rejects_dirty 'revision-expression refspec' HEAD~0

if ! printf '%s %s %s %s\n' \
  refs/tags/v1 "$candidate_commit" refs/tags/v1 0000000000000000000000000000000000000000 | \
  (cd "$repository" && bash .githooks/pre-push origin); then
  fail 'tag-only push did not skip the candidate preflight'
fi

if ! printf '%s %s %s %s\n' \
  '(delete)' 0000000000000000000000000000000000000000 refs/heads/old "$candidate_commit" | \
  (cd "$repository" && bash .githooks/pre-push origin); then
  fail 'branch deletion did not skip the candidate preflight'
fi

set +e
multi_output=$(
  {
    printf '%s %s %s %s\n' refs/heads/one "$candidate_commit" refs/heads/one 0000000000000000000000000000000000000000
    printf '%s %s %s %s\n' refs/heads/two "$base_commit" refs/heads/two 0000000000000000000000000000000000000000
  } | (cd "$repository" && bash .githooks/pre-push origin) 2>&1
)
multi_status=$?
set -e
[[ $multi_status -ne 0 ]] || fail 'multiple candidate SHAs unexpectedly passed'
[[ $multi_output == *'supports one candidate commit per push'* ]] || fail "multiple candidate SHAs reported an unexpected error: $multi_output"

echo 'preflight tests passed'
