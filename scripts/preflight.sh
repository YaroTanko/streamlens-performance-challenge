#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [base-ref]" >&2
  echo "default base ref: STREAMLENS_BASE_REF or origin/main" >&2
}

if (( $# > 1 )); then
  usage
  exit 2
fi

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository=$(cd "$script_directory/.." && pwd)
cd "$repository"

for tool in bash git go gofmt; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "preflight requires $tool in PATH" >&2
    exit 2
  fi
done

if [[ -n $(git status --porcelain --untracked-files=all) ]]; then
  echo "preflight requires a clean worktree so checks match the commit being pushed:" >&2
  git status --short >&2
  exit 1
fi

base_ref=${1:-${STREAMLENS_BASE_REF:-origin/main}}
if ! base_commit=$(git rev-parse --verify "$base_ref^{commit}" 2>/dev/null); then
  echo "cannot resolve preflight base ref: $base_ref" >&2
  echo "pass a base ref explicitly or set STREAMLENS_BASE_REF" >&2
  exit 2
fi
candidate_commit=$(git rev-parse --verify 'HEAD^{commit}')

echo "Preflight scope: $base_commit..$candidate_commit"
bash "$repository/scripts/check-protected.sh" "$base_commit" "$candidate_commit"

engine_snapshot=$(mktemp "${TMPDIR:-/tmp}/streamlens-engine.XXXXXX")
cleanup() {
  rm -f "$engine_snapshot"
}
trap cleanup EXIT
git show "$candidate_commit:internal/analyzer/engine.go" >"$engine_snapshot"
if [[ -n $(gofmt -l "$engine_snapshot") ]]; then
  echo "internal/analyzer/engine.go is not gofmt-formatted in $candidate_commit" >&2
  exit 1
fi

echo "Running focused vet and correctness checks (benchmarks are intentionally skipped)."
go vet ./internal/analyzer ./cmd/streamlens
go test -count=1 -timeout=2m ./internal/analyzer ./cmd/streamlens ./internal/assessment

echo "Preflight passed. CI remains authoritative for comparative performance scoring."
