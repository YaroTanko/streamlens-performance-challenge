#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_directory/.." && pwd -P)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-assess-test.XXXXXX")
temporary_directory=$(cd -- "$temporary_directory" && pwd -P)
trap 'rm -rf -- "$temporary_directory"' EXIT

fail() {
  echo "assess test failed: $*" >&2
  exit 1
}

assert_contains() {
  local text=$1
  local expected=$2
  local label=$3
  [[ $text == *"$expected"* ]] || fail "$label: missing '$expected' in: $text"
}

file_mode() {
  local path=$1
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

source_checkout="$temporary_directory/candidate"
baseline_checkout="$temporary_directory/baseline"
output_parent="$temporary_directory/outputs"
mkdir -p "$source_checkout/scripts" "$source_checkout/cmd" "$source_checkout/internal/analyzer" "$output_parent"
cp "$repository_root/scripts/run-benchmarks.sh" "$source_checkout/scripts/run-benchmarks.sh"
cp -R "$repository_root/cmd/benchcompare" "$source_checkout/cmd/benchcompare"
cp -R "$repository_root/cmd/evidencemanifest" "$source_checkout/cmd/evidencemanifest"

cat >"$source_checkout/go.mod" <<'EOF'
module example.test/assessment

go 1.23
EOF
cat >"$source_checkout/internal/analyzer/engine.go" <<'EOF'
package analyzer

const implementation = "baseline"
EOF
cat >"$source_checkout/OPTIMIZATION.md" <<'EOF'
- Profile evidence: baseline fixture
- Approach: fixture
- Expected effect: fixture
- Trade-off: fixture
- Verification: fixture
EOF
cat >"$source_checkout/scripts/check-protected.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scope\t%s\t%s\t%s\n' "$PWD" "$1" "$2" >>"$ASSESS_TEST_LOG"
exit "${FAKE_SCOPE_STATUS:-0}"
EOF
cat >"$source_checkout/scripts/prepare-candidate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}
kind=candidate
[[ $1 != "$2" ]] || kind=baseline
printf 'prepare\t%s\t%s\t%s\tparent-mode=%s\n' "$1" "$2" "$3" "$(mode "$(dirname -- "$3")")" >>"$ASSESS_TEST_LOG"
mkdir -m 0700 "$3"
printf '%s\n' "$kind" >"$3/.kind"
EOF
cat >"$source_checkout/scripts/run-isolated.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'isolated\t%s\t%s' "$1" "$2" >>"$ASSESS_TEST_LOG"
if [[ $# -gt 2 ]]; then printf '\t%s' "${@:3}" >>"$ASSESS_TEST_LOG"; fi
printf '\n' >>"$ASSESS_TEST_LOG"
case "$2" in
  test)
    exit "${FAKE_TEST_STATUS:-0}"
    ;;
  benchmark)
    kind=$(<"$1/.kind")
    if [[ ${FAKE_COMPARATOR_MODE:-pass} == error && $kind == candidate ]]; then
      echo 'intentionally malformed candidate benchmark output'
      exit 0
    fi
    value=100
    if [[ $kind == candidate && ${FAKE_COMPARATOR_MODE:-pass} == pass ]]; then value=70; fi
    printf '%s\n' \
      'goos: linux' \
      'goarch: amd64' \
      'pkg: example.test/assessment/internal/assessment' \
      'cpu: fake' \
      "BenchmarkAnalyze/Balanced-1 1 $value ns/op $value B/op $value allocs/op" \
      "BenchmarkAnalyze/HighCardinality-1 1 $value ns/op $value B/op $value allocs/op" \
      "BenchmarkAnalyze/MostlyFiltered-1 1 $value ns/op $value B/op $value allocs/op" \
      'PASS' \
      $'ok\texample.test/assessment/internal/assessment\t0.01s'
    ;;
  profile)
    [[ $# -eq 5 ]] || exit 96
    [[ $3 == Balanced && $4 == 1s ]] || exit 95
    [[ ! -e $5 && ! -L $5 ]] || exit 94
    if [[ ${FAKE_PROFILE_STATUS:-0} -ne 0 ]]; then
      exit "$FAKE_PROFILE_STATUS"
    fi
    mkdir -m 0700 "$5"
    for artifact in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
      printf 'fake profile: %s\n' "$artifact" >"$5/$artifact"
    done
    echo 'fake isolated profile complete'
    ;;
  *)
    exit 97
    ;;
esac
EOF
chmod 0755 "$source_checkout/scripts/"*.sh

git -C "$source_checkout" init -q
git -C "$source_checkout" config user.name 'Assessment Test'
git -C "$source_checkout" config user.email 'assessment-test@example.invalid'
git -C "$source_checkout" add .
git -C "$source_checkout" commit -qm 'baseline fixture'
baseline_commit=$(git -C "$source_checkout" rev-parse HEAD)
git clone -q "$source_checkout" "$baseline_checkout"

# Model the trusted workflow-repin commit that follows the immutable baseline.
printf 'candidate PR base\n' >"$source_checkout/WORKFLOW_PIN"
git -C "$source_checkout" add WORKFLOW_PIN
git -C "$source_checkout" commit -qm 'workflow repin fixture'
candidate_base_commit=$(git -C "$source_checkout" rev-parse HEAD)

cat >"$source_checkout/internal/analyzer/engine.go" <<'EOF'
package analyzer

const implementation = "candidate"
EOF
cat >"$source_checkout/OPTIMIZATION.md" <<'EOF'
- Profile evidence: candidate fixture
- Approach: fixture
- Expected effect: fixture
- Trade-off: fixture
- Verification: fixture
EOF
git -C "$source_checkout" add internal/analyzer/engine.go OPTIMIZATION.md
git -C "$source_checkout" commit -qm 'candidate fixture'
candidate_commit=$(git -C "$source_checkout" rev-parse HEAD)

fsmonitor_sentinel="$temporary_directory/fsmonitor-executed"
fsmonitor_canary="$temporary_directory/hostile-fsmonitor.sh"
cat >"$fsmonitor_canary" <<EOF
#!/usr/bin/env bash
printf 'args=%s\nconfig=%s\n' "\$*" "\${GIT_CONFIG_PARAMETERS:-unset}" >"$fsmonitor_sentinel"
exit 1
EOF
chmod 0755 "$fsmonitor_canary"
git -C "$source_checkout" config core.fsmonitor "$fsmonitor_canary"
git -C "$baseline_checkout" config core.fsmonitor "$fsmonitor_canary"
[[ ! -e $fsmonitor_sentinel ]] || fail "configuring core.fsmonitor unexpectedly executed it"

image="example.test/go@sha256:$(printf '0%.0s' {1..64})"
assessment_script="$repository_root/scripts/assess.sh"

run_assessment() {
  local output=$1
  local log=$2
  local comparator_mode=${3:-pass}
  local scope_status=${4:-0}
  local test_status=${5:-0}
  local profile_status=${6:-0}
  local requested_profile_time=${7:-1s}
  set +e
  assessment_output=$(
    ASSESSMENT_DOCKER_IMAGE="$image" \
    ASSESS_TEST_LOG="$log" \
    FAKE_COMPARATOR_MODE="$comparator_mode" \
    FAKE_SCOPE_STATUS="$scope_status" \
    FAKE_TEST_STATUS="$test_status" \
    FAKE_PROFILE_STATUS="$profile_status" \
    BENCH_SAMPLES=5 \
    BENCH_TIME=1x \
    BENCH_GOMAXPROCS=1 \
    PROFILE_SCENARIO=Balanced \
    PROFILE_TIME="$requested_profile_time" \
      bash "$assessment_script" \
        "$baseline_checkout" "$source_checkout" \
        "$baseline_commit" "$candidate_base_commit" "$candidate_commit" "$output" 2>&1
  )
  assessment_status=$?
  set -e
}

happy_output="$output_parent/happy"
happy_log="$temporary_directory/happy.log"
: >"$happy_log"
run_assessment "$happy_output" "$happy_log" pass
[[ $assessment_status -eq 0 ]] || fail "happy flow exited $assessment_status: $assessment_output"
[[ ! -e $fsmonitor_sentinel ]] || fail "checkout-local core.fsmonitor executed on the host: $(<"$fsmonitor_sentinel")"
[[ $(file_mode "$happy_output") == 700 ]] || fail "output directory is not mode 700"
for artifact in \
  benchmarks/baseline.txt \
  benchmarks/candidate.txt \
  benchmarks/environment.txt \
  benchmarks/report.md \
  functional.txt \
  profile.txt \
  profiles/assessment.test \
  profiles/cpu.pprof \
  profiles/alloc.pprof \
  profiles/cpu-top.txt \
  profiles/alloc-top.txt \
  evidence/manifest-core.json \
  evidence/manifest.json; do
  [[ -f $happy_output/$artifact && ! -L $happy_output/$artifact ]] || fail "happy flow missing $artifact"
done
assert_contains "$(<"$happy_output/benchmarks/report.md")" '✅ **Performance gate passed:**' 'happy report'
happy_core=$(<"$happy_output/evidence/manifest-core.json")
assert_contains "$happy_core" "\"sha\": \"$baseline_commit\"" 'assessment baseline revision evidence'
assert_contains "$happy_core" "\"sha\": \"$candidate_base_commit\"" 'candidate base revision evidence'
assert_contains "$happy_core" "\"sha\": \"$candidate_commit\"" 'candidate revision evidence'
assert_contains "$happy_core" '"name": "profile.status"' 'profile status key evidence'
assert_contains "$happy_core" '"value": "captured"' 'profile status evidence'
assert_contains "$happy_core" '"path": "functional.txt"' 'functional output evidence'
assert_contains "$happy_core" '"path": "benchmarks/report.md"' 'report artifact evidence'
assert_contains "$happy_core" '"path": "profiles/cpu.pprof"' 'CPU profile evidence'
assert_contains "$happy_core" '"path": "profiles/alloc.pprof"' 'allocation profile evidence'
assert_contains "$(<"$happy_output/evidence/manifest.json")" '"path": "manifest-core.json"' 'manifest envelope'

work_parent=$(awk -F '\t' '$1 == "prepare" { print $5; exit }' "$happy_log")
[[ $work_parent == parent-mode=700 ]] || fail "private work directory mode log = $work_parent"
prepared_baseline=$(awk -F '\t' '$1 == "prepare" && $2 == $3 { print $4; exit }' "$happy_log")
[[ -n $prepared_baseline ]] || fail "baseline was not prepared symmetrically"
mapfile_supported=true
if ! command -v mapfile >/dev/null 2>&1; then mapfile_supported=false; fi
if [[ $mapfile_supported == true ]]; then
  mapfile -t isolated_lines < <(awk -F '\t' '$1 == "isolated" { print $0 }' "$happy_log")
else
  isolated_lines=()
  while IFS= read -r line; do isolated_lines+=("$line"); done < <(awk -F '\t' '$1 == "isolated" { print $0 }' "$happy_log")
fi
[[ ${#isolated_lines[@]} -eq 12 ]] || fail "isolated invocation count = ${#isolated_lines[@]}, want 12"
candidate_prepared=$(awk -F '\t' '$1 == "prepare" && $2 != $3 { print $4; exit }' "$happy_log")
[[ ${isolated_lines[0]} == $'isolated\t'"$candidate_prepared"$'\ttest' ]] || fail "functional invocation arguments are incorrect"
expected_kinds=(baseline candidate candidate baseline baseline candidate candidate baseline baseline candidate)
for index in "${!expected_kinds[@]}"; do
  expected_directory=$prepared_baseline
  [[ ${expected_kinds[$index]} == baseline ]] || expected_directory=$candidate_prepared
  expected_line=$'isolated\t'"$expected_directory"$'\tbenchmark\t1x\t1'
  [[ ${isolated_lines[$((index + 1))]} == "$expected_line" ]] || fail "benchmark invocation $((index + 1)) = ${isolated_lines[$((index + 1))]}"
done
expected_profile_line=$'isolated\t'"$candidate_prepared"$'\tprofile\tBalanced\t1s\t'"$happy_output/profiles"
[[ ${isolated_lines[11]} == "$expected_profile_line" ]] || fail "profile invocation = ${isolated_lines[11]}"
scope_line=$(awk -F '\t' '$1 == "scope" { print $0 }' "$happy_log")
[[ $scope_line == $'scope\t'"$source_checkout"$'\t'"$candidate_base_commit"$'\t'"$candidate_commit" ]] || fail "scope arguments = $scope_line"

scope_output="$output_parent/scope-failure"
scope_log="$temporary_directory/scope.log"
: >"$scope_log"
run_assessment "$scope_output" "$scope_log" pass 23 0
[[ $assessment_status -eq 23 ]] || fail "scope failure status = $assessment_status"
assert_contains "$assessment_output" 'assess: protected-scope validation failed (exit 23)' 'scope diagnostic'
[[ $(awk -F '\t' '$1 != "scope" { count++ } END { print count + 0 }' "$scope_log") -eq 0 ]] || fail "scope failure executed a later stage"

test_output="$output_parent/test-failure"
test_log="$temporary_directory/test.log"
: >"$test_log"
run_assessment "$test_output" "$test_log" pass 0 19
[[ $assessment_status -eq 19 ]] || fail "functional failure status = $assessment_status"
assert_contains "$assessment_output" 'assess: functional tests failed (exit 19)' 'functional diagnostic'
[[ $(awk -F '\t' '$1 == "isolated" && $3 == "benchmark" { count++ } END { print count + 0 }' "$test_log") -eq 0 ]] || fail "functional failure ran benchmarks"

profile_failure_output="$output_parent/profile-failure"
profile_failure_log="$temporary_directory/profile-failure.log"
: >"$profile_failure_log"
run_assessment "$profile_failure_output" "$profile_failure_log" pass 0 0 17
[[ $assessment_status -eq 2 ]] || fail "profile failure status = $assessment_status"
assert_contains "$assessment_output" 'assess: isolated profile capture failed (exit 17)' 'profile failure diagnostic'
[[ -f $profile_failure_output/evidence/manifest-core.json && ! -L $profile_failure_output/evidence/manifest-core.json ]] || fail "profile failure did not retain evidence"
profile_failure_core=$(<"$profile_failure_output/evidence/manifest-core.json")
assert_contains "$profile_failure_core" '"value": "failed-exit-17"' 'failed profile status evidence'
assert_contains "$profile_failure_core" '"path": "profile.txt"' 'failed profile output evidence'
[[ ! -e $profile_failure_output/profiles && ! -L $profile_failure_output/profiles ]] || fail "failed profile published artifacts"

zero_profile_output="$output_parent/zero-profile-time"
zero_profile_log="$temporary_directory/zero-profile-time.log"
: >"$zero_profile_log"
run_assessment "$zero_profile_output" "$zero_profile_log" pass 0 0 0 00.000s
[[ $assessment_status -eq 2 ]] || fail "zero decimal profile time status = $assessment_status"
assert_contains "$assessment_output" 'PROFILE_TIME must be greater than zero' 'zero decimal profile time diagnostic'
[[ ! -e $zero_profile_output && ! -L $zero_profile_output ]] || fail "zero profile time created output"
[[ ! -s $zero_profile_log ]] || fail "zero profile time executed assessment stages"

gate_output="$output_parent/gate"
gate_log="$temporary_directory/gate.log"
: >"$gate_log"
run_assessment "$gate_output" "$gate_log" gate
[[ $assessment_status -eq 1 ]] || fail "comparator gate status = $assessment_status: $assessment_output"
[[ -f $gate_output/benchmarks/report.md && -f $gate_output/evidence/manifest.json ]] || fail "gate failure did not publish report and evidence"
assert_contains "$(<"$gate_output/benchmarks/report.md")" '❌ **Performance gate failed:**' 'gate report'

comparison_error_output="$output_parent/comparison-error"
comparison_error_log="$temporary_directory/comparison-error.log"
: >"$comparison_error_log"
run_assessment "$comparison_error_output" "$comparison_error_log" error
[[ $assessment_status -eq 2 ]] || fail "comparator error status = $assessment_status: $assessment_output"
[[ -f $comparison_error_output/benchmarks/report.md && -f $comparison_error_output/evidence/manifest.json ]] || fail "comparator error did not publish report and evidence"
assert_contains "$(<"$comparison_error_output/benchmarks/report.md")" '❌ Comparison failed:' 'comparison error report'

git -C "$source_checkout" -c core.fsmonitor=false update-index --assume-unchanged internal/analyzer/engine.go
index_flag_output="$output_parent/index-flags"
index_flag_log="$temporary_directory/index-flags.log"
: >"$index_flag_log"
run_assessment "$index_flag_output" "$index_flag_log" pass
[[ $assessment_status -eq 2 ]] || fail "unsupported index flag status = $assessment_status"
assert_contains "$assessment_output" 'unsupported assume-unchanged or skip-worktree index flags' 'index flag diagnostic'
[[ ! -e $index_flag_output && ! -L $index_flag_output ]] || fail "unsupported index flag created output"
[[ ! -s $index_flag_log ]] || fail "unsupported index flag executed assessment stages"
git -C "$source_checkout" -c core.fsmonitor=false update-index --no-assume-unchanged internal/analyzer/engine.go

unsafe_output_parent="$temporary_directory/unsafe-output-parent"
mkdir "$unsafe_output_parent"
chmod 0777 "$unsafe_output_parent"
unsafe_output_log="$temporary_directory/unsafe-output.log"
: >"$unsafe_output_log"
run_assessment "$unsafe_output_parent/assessment" "$unsafe_output_log" pass
[[ $assessment_status -eq 2 ]] || fail "unsafe output parent status = $assessment_status"
assert_contains "$assessment_output" 'output parent must not be group- or world-writable' 'unsafe output parent diagnostic'
[[ ! -e $unsafe_output_parent/assessment && ! -L $unsafe_output_parent/assessment ]] || fail "unsafe output parent received output"
[[ ! -s $unsafe_output_log ]] || fail "unsafe output parent executed assessment stages"

existing_output="$output_parent/existing"
mkdir "$existing_output"
existing_log="$temporary_directory/existing.log"
: >"$existing_log"
run_assessment "$existing_output" "$existing_log" pass
[[ $assessment_status -eq 2 ]] || fail "existing output status = $assessment_status"
assert_contains "$assessment_output" 'output directory must not already exist' 'existing output diagnostic'
[[ ! -s $existing_log ]] || fail "existing output rejection executed assessment stages"

echo 'assess self-test passed'
