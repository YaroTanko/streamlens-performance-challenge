#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fixture_directory="$script_directory/testdata/prepare-candidate"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-prepare-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "prepare-candidate-test: $*" >&2
  exit 1
}

expect_failure() {
  local label=$1
  local expected=$2
  shift 2
  local output

  if output=$("$@" 2>&1); then
    fail "$label unexpectedly succeeded"
  fi
  [[ $output == *"$expected"* ]] || fail "$label reported unexpected error: $output"
}

baseline="$temporary_directory/baseline"
candidate="$temporary_directory/candidate"
prepared="$temporary_directory/prepared"
cp -a "$fixture_directory/baseline" "$baseline"
cp -a "$fixture_directory/candidate" "$candidate"
mkdir -p "$baseline/.git/objects"
printf 'trusted git metadata\n' >"$baseline/.git/HEAD"
printf 'gitdir: candidate-controlled-submodule-metadata\n' >"$candidate/vendor-submodule/.git"
ln -s / "$candidate/ignored-link"
mkfifo "$candidate/ignored-pipe"

bash "$script_directory/prepare-candidate.sh" "$baseline" "$candidate" "$prepared" >/dev/null

cmp -s "$candidate/internal/analyzer/engine.go" "$prepared/internal/analyzer/engine.go" || fail "engine.go was not overlaid"
cmp -s "$candidate/OPTIMIZATION.md" "$prepared/OPTIMIZATION.md" || fail "OPTIMIZATION.md was not overlaid"
cmp -s "$baseline/internal/assessment/benchmark_test.go" "$prepared/internal/assessment/benchmark_test.go" || fail "candidate benchmark replaced the trusted benchmark"
cmp -s "$baseline/scripts/trusted.sh" "$prepared/scripts/trusted.sh" || fail "candidate script replaced a trusted script"
[[ ! -e $prepared/generated.go ]] || fail "candidate generated file entered the prepared tree"
[[ ! -e $prepared/.gitmodules ]] || fail "candidate submodule metadata entered the prepared tree"
[[ ! -e $prepared/vendor-submodule ]] || fail "candidate submodule tree entered the prepared tree"
[[ ! -e $prepared/ignored-link ]] || fail "candidate extra symlink entered the prepared tree"
[[ ! -e $prepared/ignored-pipe ]] || fail "candidate extra special file entered the prepared tree"
[[ ! -e $prepared/.git ]] || fail "baseline Git metadata entered the prepared tree"

printf 'candidate changed after preparation\n' >"$candidate/internal/analyzer/engine.go"
[[ $(<"$prepared/internal/analyzer/engine.go") == "package analyzer // candidate overlay" ]] || fail "prepared tree aliases the candidate checkout"

symlink_candidate="$temporary_directory/symlink-candidate"
cp -a "$fixture_directory/candidate" "$symlink_candidate"
rm -- "$symlink_candidate/internal/analyzer/engine.go"
ln -s ../../OPTIMIZATION.md "$symlink_candidate/internal/analyzer/engine.go"
expect_failure "allowed symlink" "not a symbolic link" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$symlink_candidate" "$temporary_directory/symlink-output"

component_candidate="$temporary_directory/component-candidate"
cp -a "$fixture_directory/candidate" "$component_candidate"
mv "$component_candidate/internal/analyzer" "$component_candidate/internal/real-analyzer"
ln -s real-analyzer "$component_candidate/internal/analyzer"
expect_failure "symlink component" "symbolic-link path component" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$component_candidate" "$temporary_directory/component-output"

fifo_candidate="$temporary_directory/fifo-candidate"
cp -a "$fixture_directory/candidate" "$fifo_candidate"
rm -- "$fifo_candidate/OPTIMIZATION.md"
mkfifo "$fifo_candidate/OPTIMIZATION.md"
expect_failure "non-regular allowed file" "must be a regular file" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$fifo_candidate" "$temporary_directory/fifo-output"

renamed_candidate="$temporary_directory/renamed-candidate"
cp -a "$fixture_directory/candidate" "$renamed_candidate"
mv "$renamed_candidate/internal/analyzer/engine.go" "$renamed_candidate/internal/analyzer/renamed.go"
expect_failure "renamed allowed file" "must be a regular file" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$renamed_candidate" "$temporary_directory/renamed-output"

victim="$temporary_directory/victim"
mkdir "$victim"
printf 'must survive\n' >"$victim/sentinel"
ln -s "$victim" "$temporary_directory/output-link"
expect_failure "symlink output" "must not be a symbolic link" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$fixture_directory/candidate" "$temporary_directory/output-link"
[[ $(<"$victim/sentinel") == "must survive" ]] || fail "symlink output target was modified"

existing_output="$temporary_directory/existing-output"
mkdir "$existing_output"
printf 'must survive\n' >"$existing_output/sentinel"
expect_failure "existing output" "must not already exist" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$fixture_directory/candidate" "$existing_output"
[[ $(<"$existing_output/sentinel") == "must survive" ]] || fail "existing output was modified"

insecure_parent="$temporary_directory/insecure-parent"
mkdir "$insecure_parent"
chmod 0777 "$insecure_parent"
expect_failure "world-writable output parent" "must not be group- or world-writable" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$fixture_directory/candidate" "$insecure_parent/prepared"
[[ ! -e $insecure_parent/prepared ]] || fail "output was published under an insecure parent"

# Default macOS filesystems are commonly case-insensitive. On such a filesystem,
# a differently-cased spelling of the baseline must be recognized as existing
# before the staging tree is created or published.
case_variant="$temporary_directory/BASELINE"
if [[ -e $case_variant ]]; then
  expect_failure "case-folded baseline output" "must not already exist" \
    bash "$script_directory/prepare-candidate.sh" "$baseline" "$fixture_directory/candidate" "$case_variant"
  [[ -f $baseline/internal/analyzer/engine.go ]] || fail "case-folded output damaged the baseline"
fi

expect_failure "candidate overlap" "overlaps the candidate" \
  bash "$script_directory/prepare-candidate.sh" "$baseline" "$fixture_directory/candidate" "$fixture_directory/candidate/prepared"

echo "prepare-candidate tests passed"
