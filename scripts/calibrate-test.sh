#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_directory/.." && pwd -P)
fixture_source="$repository_root/internal/assessment/testdata/calibration"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-calibrate-test.XXXXXX")
temporary_directory=$(cd -- "$temporary_directory" && pwd -P)
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "calibrate-test: $*" >&2
  exit 1
}

expect_failure() {
  local label=$1
  local expected=$2
  shift 2
  local output
  local status

  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  ((status != 0)) || fail "$label unexpectedly succeeded"
  [[ $output == *"$expected"* ]] || fail "$label reported an unexpected error: $output"
}

sandbox="$temporary_directory/sandbox"
mkdir -p "$sandbox/scripts" "$sandbox/internal/assessment/testdata"
cp "$script_directory/calibrate.sh" "$sandbox/scripts/calibrate.sh"
cp -a "$fixture_source" "$sandbox/internal/assessment/testdata/calibration"

for control in prepare-candidate-test check-protected-test isolation-test; do
  cat >"$sandbox/scripts/$control.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "$control construction control passed"
if [[ "$control" == isolation-test && \${REQUIRE_DOCKER_RUNTIME:-0} != 1 ]]; then
  echo "real Docker runtime was not required" >&2
  exit 90
fi
EOF
done

fake_bin="$temporary_directory/fake-bin"
mkdir "$fake_bin"
cat >"$fake_bin/go" <<'FAKE_GO'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == *'-tags reference'* ]] || exit 95
[[ $* == *"-run ^TestReferenceScenarioResults$"* ]] || exit 96
echo '--- PASS: TestReferenceScenarioResults (0.01s)'
FAKE_GO
chmod 0755 "$fake_bin/go"

cat >"$sandbox/scripts/assess.sh" <<'FAKE_ASSESS'
#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 6 ]] || exit 90
baseline=$1
candidate=$2
baseline_commit=$3
candidate_base_commit=$4
candidate_commit=$5
output=$6
[[ $(git -C "$baseline" rev-parse HEAD) == "$baseline_commit" ]] || exit 91
[[ $(git -C "$candidate" cat-file -t "$candidate_base_commit") == commit ]] || exit 94
[[ $(git -C "$candidate" rev-parse HEAD) == "$candidate_commit" ]] || exit 92
mkdir -p "$output/benchmarks"
printf '%s\n' "$candidate" >>"${FAKE_ASSESS_LOG:?}"

write_report() {
  local tier=$1
  local first_improvement=$2
  local gate=$3
  cat >"$output/benchmarks/report.md" <<EOF
# Benchmark comparison

| Scenario | Metric | Baseline | Candidate | Improvement |
| --- | ---: | ---: | ---: | ---: |
| Balanced | ns/op | 100 | 99 | +${FAKE_SCENARIO_NOISE:-3.00}% |
| Balanced | B/op | 100 | 100 | +0.00% |
| Balanced | allocs/op | 100 | 100 | +0.00% |
| HighCardinality | ns/op | 100 | 99 | +1.00% |
| HighCardinality | B/op | 100 | 100 | +0.00% |
| HighCardinality | allocs/op | 100 | 100 | +0.00% |
| MostlyFiltered | ns/op | 100 | 99 | +1.00% |
| MostlyFiltered | B/op | 100 | 100 | +0.00% |
| MostlyFiltered | allocs/op | 100 | 100 | +0.00% |

## Geometric-mean result

| Metric | Improvement | Tier |
| --- | ---: | --- |
| ns/op | +${first_improvement}% | $tier |
| B/op | -1.00% | Below target |
| allocs/op | +0.50% | Below target |

**Overall optimization tier: $tier**

$gate
EOF
  if [[ ${FAKE_INCOMPLETE_REPORT:-0} == 1 ]]; then
    awk '!/HighCardinality|MostlyFiltered/' "$output/benchmarks/report.md" >"$output/benchmarks/report.tmp"
    mv "$output/benchmarks/report.tmp" "$output/benchmarks/report.md"
  fi
}

if [[ $candidate == "${FAKE_AA_DIR:?}" ]]; then
  write_report 'Below target' "${FAKE_AA_NOISE:-2.00}" '❌ Performance gate failed.'
  exit 1
fi
if [[ $candidate == "${FAKE_OPTIMIZED_DIR:?}" ]]; then
  write_report 'Senior' '55.00' '✅ Performance gate passed.'
  exit 0
fi

engine="$candidate/internal/analyzer/engine.go"
if git -C "$candidate" diff-tree \
    -r --no-commit-id --name-status --find-renames --find-copies-harder \
    "$candidate_base_commit" "$candidate_commit" |
    awk -F '\t' '$1 ~ /^C[0-9]+$/ && $3 == "CALIBRATION_PROTECTED_CANARY.txt" { found = 1 } END { exit !found }'; then
  echo 'Copy changes are not allowed before protected-path validation.'
  echo 'assess: protected-scope validation failed (exit 1)'
  exit 1
fi
if [[ -f $candidate/CALIBRATION_PROTECTED_CANARY.txt ]]; then
  echo 'Protected assessment path changed: CALIBRATION_PROTECTED_CANARY.txt'
  echo 'assess: protected-scope validation failed (exit 1)'
  exit 1
fi
if grep -Fq 'calibrationFakeBenchmarkOutput' "$engine"; then
  echo 'source audit: rejected fmt.Println'
  echo 'assess: protected-scope validation failed (exit 1)'
  exit 1
fi
if grep -Fq '"os/exec"' "$engine"; then
  echo 'source audit: rejected import "os/exec"'
  echo 'assess: protected-scope validation failed (exit 1)'
  exit 1
fi
if grep -Fq '"os"' "$engine"; then
  echo 'source audit: rejected import "os"'
  echo 'assess: protected-scope validation failed (exit 1)'
  exit 1
fi
if grep -Fq 'return []Group{}, nil' "$engine"; then
  echo 'trusted result oracle rejected incorrect aggregate'
  echo 'assess: functional tests failed (exit 1)'
  exit 1
fi

echo 'fake assess: unknown candidate' >&2
exit 93
FAKE_ASSESS

new_repository() {
  local directory=$1
  mkdir -p "$directory/internal/analyzer"
  git -C "$directory" init -q
  git -C "$directory" config user.name 'Calibration Test'
  git -C "$directory" config user.email 'calibration-test@example.invalid'
  cat >"$directory/internal/analyzer/engine.go" <<'EOF'
package analyzer

func baselineImplementation() int { return 1 }
EOF
  cat >"$directory/internal/analyzer/types.go" <<'EOF'
package analyzer

type Group struct{}
type Config struct{}
EOF
  cp "$fixture_source/valid_optimization.md" "$directory/OPTIMIZATION.md"
  git -C "$directory" add -- internal/analyzer/engine.go internal/analyzer/types.go OPTIMIZATION.md
  git -C "$directory" commit -qm baseline
}

baseline="$temporary_directory/baseline"
neutral="$temporary_directory/neutral"
optimized="$temporary_directory/optimized"
new_repository "$baseline"
base_commit=$(git -C "$baseline" rev-parse HEAD)

git clone -q --no-hardlinks "$baseline" "$neutral"
git -C "$neutral" config user.name 'Calibration Test'
git -C "$neutral" config user.email 'calibration-test@example.invalid'
printf '%s\n' '// streamlens-calibration-neutral' >>"$neutral/internal/analyzer/engine.go"
printf '\n- Neutral commit marker.\n' >>"$neutral/OPTIMIZATION.md"
git -C "$neutral" add -- internal/analyzer/engine.go OPTIMIZATION.md
git -C "$neutral" commit -qm neutral
neutral_commit=$(git -C "$neutral" rev-parse HEAD)

git clone -q --no-hardlinks "$baseline" "$optimized"
git -C "$optimized" config user.name 'Calibration Test'
git -C "$optimized" config user.email 'calibration-test@example.invalid'
printf '\n// Known optimized calibration implementation.\n' >>"$optimized/internal/analyzer/engine.go"
printf '\n- Optimized commit marker.\n' >>"$optimized/OPTIMIZATION.md"
git -C "$optimized" add -- internal/analyzer/engine.go OPTIMIZATION.md
git -C "$optimized" commit -qm optimized
optimized_commit=$(git -C "$optimized" rev-parse HEAD)

fake_assess_log="$temporary_directory/fake-assess.log"
: >"$fake_assess_log"

run_calibration() {
  local output=$1
  local minimum_tier=$2
  env \
    PATH="$fake_bin:$PATH" \
    BENCH_SAMPLES="${TEST_BENCH_SAMPLES:-5}" \
    BENCH_TIME="${TEST_BENCH_TIME:-1x}" \
    BENCH_GOMAXPROCS=1 \
    FAKE_AA_DIR="$neutral" \
    FAKE_OPTIMIZED_DIR="$optimized" \
    FAKE_ASSESS_LOG="$fake_assess_log" \
    FAKE_AA_NOISE="${FAKE_AA_NOISE:-2.00}" \
    FAKE_SCENARIO_NOISE="${FAKE_SCENARIO_NOISE:-3.00}" \
    FAKE_INCOMPLETE_REPORT="${FAKE_INCOMPLETE_REPORT:-0}" \
    bash "$sandbox/scripts/calibrate.sh" \
      --baseline-dir "$baseline" --baseline-commit "$base_commit" \
      --aa-dir "$neutral" --aa-base-commit "$base_commit" --aa-commit "$neutral_commit" \
      --optimized-dir "$optimized" --optimized-base-commit "$base_commit" --optimized-commit "$optimized_commit" \
      --optimized-min-tier "$minimum_tier" \
      --optimized-max-tier "${OPTIMIZED_MAX_TIER:-Senior}" \
      --output-dir "$output" \
      --max-wall-seconds 60
}

expect_failure 'missing arguments' 'usage: scripts/calibrate.sh' bash "$sandbox/scripts/calibrate.sh"

success_output="$temporary_directory/evidence-success"
run_calibration "$success_output" Middle >/dev/null
[[ $(<"$success_output/status.txt") == smoke-complete ]] || fail 'smoke calibration was incorrectly marked as release-complete'
[[ -f $success_output/calibration-summary.md ]] || fail 'calibration summary is missing'
grep -Fq 'Calibration mode: smoke (not release evidence)' "$success_output/calibration-summary.md" || fail 'smoke mode was not summarized'
grep -Fq 'A/A maximum absolute reported change: 3.00%' "$success_output/calibration-summary.md" || fail 'A/A scenario maximum was not summarized'
grep -Fq 'Optimized tier: Senior (expected Middle through Senior)' "$success_output/calibration-summary.md" || fail 'optimized tier range was not summarized'
grep -Fq 'prepare-candidate-test construction control passed' "$success_output/controls/preparation.log" || fail 'preparation control was not retained'
grep -Fq 'check-protected-test construction control passed' "$success_output/controls/scope.log" || fail 'scope control was not retained'
grep -Fq 'isolation-test construction control passed' "$success_output/controls/isolation.log" || fail 'isolation control was not retained'
grep -Fq -- '--- PASS: TestReferenceScenarioResults' "$success_output/controls/reference.log" || fail 'independent reference oracle was not retained'
[[ $(wc -l <"$success_output/adversarial/results.tsv" | tr -d '[:space:]') == 7 ]] || fail 'not every adversarial result was retained'
[[ $(wc -l <"$fake_assess_log" | tr -d '[:space:]') == 8 ]] || fail 'expected six adversarial and two measured assessments'

release_output="$temporary_directory/evidence-release"
TEST_BENCH_SAMPLES=7 TEST_BENCH_TIME=300ms run_calibration "$release_output" Middle >/dev/null
[[ $(<"$release_output/status.txt") == complete ]] || fail 'release parameters were not marked complete'
grep -Fq 'Calibration mode: release' "$release_output/calibration-summary.md" || fail 'release mode was not summarized'

existing_output="$temporary_directory/existing-output"
mkdir "$existing_output"
printf 'preserve\n' >"$existing_output/sentinel"
expect_failure 'existing output' 'must not already exist' run_calibration "$existing_output" Middle
[[ $(<"$existing_output/sentinel") == preserve ]] || fail 'existing output was modified'

expect_failure 'mismatched A/A HEAD' 'does not match requested commit' \
  env BENCH_SAMPLES=5 BENCH_TIME=1x FAKE_AA_DIR="$neutral" FAKE_OPTIMIZED_DIR="$optimized" FAKE_ASSESS_LOG="$fake_assess_log" \
  bash "$sandbox/scripts/calibrate.sh" \
    --baseline-dir "$baseline" --baseline-commit "$base_commit" \
    --aa-dir "$neutral" --aa-base-commit "$base_commit" --aa-commit "$base_commit" \
    --optimized-dir "$optimized" --optimized-base-commit "$base_commit" --optimized-commit "$optimized_commit" \
    --optimized-min-tier Middle --optimized-max-tier Senior --output-dir "$temporary_directory/mismatch-output"

printf 'dirty\n' >"$neutral/untracked-canary"
expect_failure 'dirty input' 'A/A checkout must be clean' run_calibration "$temporary_directory/dirty-output" Middle
rm -- "$neutral/untracked-canary"

expect_failure 'output overlap' 'must not overlap an input checkout' run_calibration "$baseline/calibration-output" Middle
[[ ! -e $baseline/calibration-output ]] || fail 'overlapping output was created'

unsafe_output_parent="$temporary_directory/unsafe-output-parent"
mkdir "$unsafe_output_parent"
chmod 0777 "$unsafe_output_parent"
expect_failure 'unsafe output parent' 'must not be group- or world-writable' \
  run_calibration "$unsafe_output_parent/calibration" Middle
[[ ! -e $unsafe_output_parent/calibration ]] || fail 'unsafe output parent received calibration output'

FAKE_AA_NOISE=12.00 expect_failure 'A/A noise guard' 'noise 12.00% exceeds 10%' \
  run_calibration "$temporary_directory/noisy-output" Middle
[[ $(<"$temporary_directory/noisy-output/status.txt") == 'failed exit=1' ]] || fail 'failed noise run status was not retained'

FAKE_INCOMPLETE_REPORT=1 expect_failure 'incomplete A/A report' 'cannot parse all A/A scenario metrics' \
  run_calibration "$temporary_directory/incomplete-output" Middle
[[ $(<"$temporary_directory/incomplete-output/status.txt") == 'failed exit=1' ]] || fail 'incomplete report status was not retained'

OPTIMIZED_MAX_TIER=Staff expect_failure 'optimized minimum tier' 'optimized tier Senior is below required Staff' \
  run_calibration "$temporary_directory/tier-output" Staff
[[ $(<"$temporary_directory/tier-output/status.txt") == 'failed exit=1' ]] || fail 'failed tier run status was not retained'

OPTIMIZED_MAX_TIER=Middle expect_failure 'optimized maximum tier' 'optimized tier Senior is above allowed Middle' \
  run_calibration "$temporary_directory/upper-tier-output" Middle
[[ $(<"$temporary_directory/upper-tier-output/status.txt") == 'failed exit=1' ]] || fail 'failed upper-tier run status was not retained'

missing_root="$temporary_directory/missing-entrypoint"
mkdir -p "$missing_root/scripts" "$missing_root/internal/assessment/testdata"
cp "$script_directory/calibrate.sh" "$missing_root/scripts/calibrate.sh"
cp -a "$fixture_source" "$missing_root/internal/assessment/testdata/calibration"
expect_failure 'missing assess interface' 'expected contract: scripts/assess.sh' \
  bash "$missing_root/scripts/calibrate.sh" \
    --baseline-dir "$baseline" --baseline-commit "$base_commit" \
    --aa-dir "$neutral" --aa-base-commit "$base_commit" --aa-commit "$neutral_commit" \
    --optimized-dir "$optimized" --optimized-base-commit "$base_commit" --optimized-commit "$optimized_commit" \
    --optimized-min-tier Middle --optimized-max-tier Senior --output-dir "$temporary_directory/missing-assess-output"

[[ -z $(git -C "$baseline" status --porcelain=v1 --untracked-files=all) ]] || fail 'baseline checkout was mutated'
[[ -z $(git -C "$neutral" status --porcelain=v1 --untracked-files=all) ]] || fail 'neutral checkout was mutated'
[[ -z $(git -C "$optimized" status --porcelain=v1 --untracked-files=all) ]] || fail 'optimized checkout was mutated'

echo 'calibrate tests passed'
