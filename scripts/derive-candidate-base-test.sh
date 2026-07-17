#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_directory=$(cd -- "$script_directory/.." && pwd -P)
derive_script="$project_directory/.github/scripts/derive-candidate-base.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-base-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "derive-candidate-base-test: $*" >&2
  exit 1
}

upstream="$temporary_directory/upstream"
candidate="$temporary_directory/candidate"
unrelated="$temporary_directory/unrelated"

git init -q -b main "$upstream"
git -C "$upstream" config user.name 'StreamLens test'
git -C "$upstream" config user.email 'streamlens-test@example.invalid'
git -C "$upstream" commit -q --allow-empty -m 'common base'
common_base=$(git -C "$upstream" rev-parse HEAD)
git -C "$upstream" commit -q --allow-empty -m 'new upstream tip'
base_tip=$(git -C "$upstream" rev-parse HEAD)

git clone -q "$upstream" "$candidate"
git -C "$candidate" config user.name 'StreamLens test'
git -C "$candidate" config user.email 'streamlens-test@example.invalid'
git -C "$candidate" switch -q -c candidate "$common_base"
git -C "$candidate" commit -q --allow-empty -m 'candidate change'
candidate_sha=$(git -C "$candidate" rev-parse HEAD)

derived=$(bash "$derive_script" "$candidate" "$upstream" "$base_tip" "$candidate_sha")
[[ $derived == "$common_base" ]] || \
  fail "expected merge base $common_base, got $derived"

git init -q -b main "$unrelated"
git -C "$unrelated" config user.name 'StreamLens test'
git -C "$unrelated" config user.email 'streamlens-test@example.invalid'
git -C "$unrelated" commit -q --allow-empty -m 'unrelated history'
unrelated_sha=$(git -C "$unrelated" rev-parse HEAD)
if bash "$derive_script" "$unrelated" "$upstream" "$base_tip" "$unrelated_sha" \
    >/dev/null 2>&1; then
  fail 'unrelated histories were accepted'
fi

if bash "$derive_script" "$candidate" "$upstream" short "$candidate_sha" \
    >/dev/null 2>&1; then
  fail 'short base SHA was accepted'
fi

tree=$(git -C "$upstream" write-tree)
criss_left=$(git -C "$upstream" commit-tree "$tree" -p "$common_base" <<<'criss left')
criss_right=$(git -C "$upstream" commit-tree "$tree" -p "$common_base" <<<'criss right')
criss_candidate=$(git -C "$upstream" commit-tree "$tree" \
  -p "$criss_left" -p "$criss_right" <<<'criss candidate')
criss_upstream=$(git -C "$upstream" commit-tree "$tree" \
  -p "$criss_right" -p "$criss_left" <<<'criss upstream')
git -C "$candidate" fetch -q "$upstream" \
  "+${criss_candidate}:refs/test/criss-candidate"
if bash "$derive_script" "$candidate" "$upstream" "$criss_upstream" "$criss_candidate" \
    >/dev/null 2>&1; then
  fail 'multiple candidate merge bases were accepted'
fi

echo 'candidate base derivation tests passed'
