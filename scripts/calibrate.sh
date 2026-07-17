#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  cat >&2 <<'USAGE'
usage: scripts/calibrate.sh \
  --baseline-dir <clean-checkout> --baseline-commit <40-sha> \
  --aa-dir <clean-neutral-candidate-checkout> \
    --aa-base-commit <40-sha> --aa-commit <40-sha> \
  --optimized-dir <clean-known-optimized-checkout> \
    --optimized-base-commit <40-sha> --optimized-commit <40-sha> \
  --optimized-min-tier <Middle|Senior|Staff> \
  --optimized-max-tier <Middle|Senior|Staff> \
  --output-dir <new-directory> \
  [--aa-max-abs-percent <percent>] [--max-wall-seconds <seconds>]

The assessment entry point must have this contract:
  scripts/assess.sh <baseline-checkout> <candidate-checkout> \
    <baseline-40-sha> <candidate-base-40-sha> <candidate-40-sha> \
    <new-output-dir>
USAGE
  exit 2
}

die() {
  echo "calibrate: $*" >&2
  exit 1
}

trusted_git() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_COMMON_DIR \
    -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CONFIG \
    -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_NOSYSTEM \
    -u GIT_EXEC_PATH \
    -u GIT_EXTERNAL_DIFF \
    -u GIT_DIFF_OPTS \
    -u GIT_PAGER \
    -u GIT_ASKPASS \
    -u GIT_SSH \
    -u GIT_SSH_COMMAND \
    -u GIT_CEILING_DIRECTORIES \
    -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    -u GIT_TRACE \
    -u GIT_TRACE2 \
    -u GIT_TRACE2_EVENT \
    -u GIT_TRACE2_PERF \
    -u GIT_TRACE_PACKET \
    -u GIT_TRACE_PERFORMANCE \
    -u GIT_TRACE_SETUP \
    -u GIT_TRACE_SHALLOW \
    -u GIT_TRACE_PACK_ACCESS \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

baseline_input=
baseline_commit=
aa_input=
aa_base_commit=
aa_commit=
optimized_input=
optimized_base_commit=
optimized_commit=
optimized_min_tier=
optimized_max_tier=
output_input=
aa_max_abs_percent=10
max_wall_seconds=3600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-dir)
      [[ $# -ge 2 && -z $baseline_input ]] || usage
      baseline_input=$2
      shift 2
      ;;
    --baseline-commit)
      [[ $# -ge 2 && -z $baseline_commit ]] || usage
      baseline_commit=$2
      shift 2
      ;;
    --aa-dir)
      [[ $# -ge 2 && -z $aa_input ]] || usage
      aa_input=$2
      shift 2
      ;;
    --aa-commit)
      [[ $# -ge 2 && -z $aa_commit ]] || usage
      aa_commit=$2
      shift 2
      ;;
    --aa-base-commit)
      [[ $# -ge 2 && -z $aa_base_commit ]] || usage
      aa_base_commit=$2
      shift 2
      ;;
    --optimized-dir)
      [[ $# -ge 2 && -z $optimized_input ]] || usage
      optimized_input=$2
      shift 2
      ;;
    --optimized-commit)
      [[ $# -ge 2 && -z $optimized_commit ]] || usage
      optimized_commit=$2
      shift 2
      ;;
    --optimized-base-commit)
      [[ $# -ge 2 && -z $optimized_base_commit ]] || usage
      optimized_base_commit=$2
      shift 2
      ;;
    --optimized-min-tier)
      [[ $# -ge 2 && -z $optimized_min_tier ]] || usage
      optimized_min_tier=$2
      shift 2
      ;;
    --optimized-max-tier)
      [[ $# -ge 2 && -z $optimized_max_tier ]] || usage
      optimized_max_tier=$2
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 && -z $output_input ]] || usage
      output_input=$2
      shift 2
      ;;
    --aa-max-abs-percent)
      [[ $# -ge 2 ]] || usage
      aa_max_abs_percent=$2
      shift 2
      ;;
    --max-wall-seconds)
      [[ $# -ge 2 ]] || usage
      max_wall_seconds=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n $baseline_input && -n $baseline_commit ]] || usage
[[ -n $aa_input && -n $aa_base_commit && -n $aa_commit ]] || usage
[[ -n $optimized_input && -n $optimized_base_commit && -n $optimized_commit ]] || usage
[[ -n $optimized_min_tier && -n $optimized_max_tier && -n $output_input ]] || usage

case "$optimized_min_tier:$optimized_max_tier" in
  Middle:Middle|Middle:Senior|Middle:Staff|Senior:Senior|Senior:Staff|Staff:Staff) ;;
  *) usage ;;
esac
if ! [[ $aa_max_abs_percent =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  usage
fi
if ! awk -v value="$aa_max_abs_percent" 'BEGIN { exit !(value > 0 && value <= 100) }'; then
  usage
fi
if ! [[ $max_wall_seconds =~ ^[1-9][0-9]{0,5}$ ]] || ((max_wall_seconds > 86400)); then
  usage
fi

samples=${BENCH_SAMPLES:-7}
bench_time=${BENCH_TIME:-300ms}
gomaxprocs=${BENCH_GOMAXPROCS:-1}
if ! [[ $samples =~ ^[0-9]+$ ]] || ((samples < 5 || samples > 15)); then
  die "BENCH_SAMPLES must be an integer between 5 and 15"
fi
if ! [[ $bench_time =~ ^([1-9][0-9]*x|[0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))$ ]]; then
  die "invalid BENCH_TIME: $bench_time"
fi
[[ $gomaxprocs == 1 ]] || die "authoritative calibration requires BENCH_GOMAXPROCS=1"

release_parameters=false
if ((samples >= 7)) && [[ $bench_time != *x ]]; then
  duration_value=${bench_time%??}
  duration_unit=${bench_time#"$duration_value"}
  # The one-character units need separate extraction from two-character units.
  if [[ $bench_time =~ (s|m|h)$ && ! $bench_time =~ (ns|us|ms)$ ]]; then
    duration_value=${bench_time%?}
    duration_unit=${bench_time#"$duration_value"}
  fi
  duration_ns=$(awk -v value="$duration_value" -v unit="$duration_unit" 'BEGIN {
    factor["ns"] = 1
    factor["us"] = 1000
    factor["ms"] = 1000000
    factor["s"] = 1000000000
    factor["m"] = 60000000000
    factor["h"] = 3600000000000
    if (!(unit in factor)) exit 1
    printf "%.0f\n", value * factor[unit]
  }') || die "cannot normalize BENCH_TIME: $bench_time"
  if awk -v value="$duration_ns" 'BEGIN { exit !(value >= 300000000) }'; then
    release_parameters=true
  fi
fi

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trusted_root=$(cd -- "$script_directory/.." && pwd -P)
assess_script="$script_directory/assess.sh"
fixture_directory="$trusted_root/internal/assessment/testdata/calibration"
fixture_manifest="$fixture_directory/canaries.tsv"

if [[ ! -f $assess_script || -L $assess_script ]]; then
  die "required assessment entry point is missing or unsafe: $assess_script; expected contract: scripts/assess.sh <baseline-checkout> <candidate-checkout> <baseline-40-sha> <candidate-base-40-sha> <candidate-40-sha> <new-output-dir>"
fi
[[ -f $fixture_manifest && ! -L $fixture_manifest ]] || die "trusted canary manifest is missing: $fixture_manifest"
fixture_file="$fixture_directory/valid_optimization.md"
[[ -f $fixture_file && ! -L $fixture_file ]] || die "trusted canary data file is missing or unsafe: $fixture_file"

physical_checkout() {
  local input=$1
  local label=$2
  local commit=$3
  local directory
  local head
  local top
  local status

  [[ $input != *$'\n'* && $input != *$'\r'* ]] || die "$label path contains a newline"
  [[ -d $input && ! -L $input ]] || die "$label must be a non-symlink directory: $input"
  directory=$(cd -- "$input" && pwd -P)
  if ! top=$(trusted_git -C "$directory" rev-parse --show-toplevel 2>/dev/null); then
    die "$label is not a Git checkout: $directory"
  fi
  top=$(cd -- "$top" && pwd -P)
  [[ $top == "$directory" ]] || die "$label must name the checkout root: $directory"
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || die "$label commit must be a full 40-character lowercase SHA"
  [[ $(trusted_git -C "$directory" cat-file -t "$commit" 2>/dev/null || true) == commit ]] || die "$label commit is unavailable: $commit"
  head=$(trusted_git -C "$directory" rev-parse HEAD)
  [[ $head == "$commit" ]] || die "$label HEAD $head does not match requested commit $commit"
  status=$(trusted_git -C "$directory" status \
    --porcelain=v1 --untracked-files=all --ignored=matching)
  [[ -z $status ]] || die "$label must be clean: $directory"
  printf '%s\n' "$directory"
}

baseline_directory=$(physical_checkout "$baseline_input" "baseline checkout" "$baseline_commit")
aa_directory=$(physical_checkout "$aa_input" "A/A checkout" "$aa_commit")
optimized_directory=$(physical_checkout "$optimized_input" "optimized checkout" "$optimized_commit")

[[ $baseline_directory != "$aa_directory" ]] || die "baseline and A/A checkouts must be separate directories"
[[ $baseline_directory != "$optimized_directory" ]] || die "baseline and optimized checkouts must be separate directories"
[[ $aa_directory != "$optimized_directory" ]] || die "A/A and optimized checkouts must be separate directories"
[[ $aa_base_commit =~ ^[0-9a-f]{40}$ ]] || die "A/A base commit must be a full 40-character lowercase SHA"
[[ $optimized_base_commit =~ ^[0-9a-f]{40}$ ]] || die "optimized base commit must be a full 40-character lowercase SHA"
[[ $aa_base_commit != "$aa_commit" ]] || die "A/A requires a distinct neutral candidate commit accepted by the scope guard"
[[ $optimized_base_commit != "$optimized_commit" ]] || die "optimized candidate commit must differ from its scope base"
[[ $(trusted_git -C "$aa_directory" cat-file -t "$aa_base_commit" 2>/dev/null || true) == commit ]] || \
  die "A/A checkout does not contain scope base commit $aa_base_commit"
[[ $(trusted_git -C "$optimized_directory" cat-file -t "$optimized_base_commit" 2>/dev/null || true) == commit ]] || \
  die "optimized checkout does not contain scope base commit $optimized_base_commit"
trusted_git -C "$aa_directory" merge-base --is-ancestor "$aa_base_commit" "$aa_commit" || \
  die "A/A scope base is not an ancestor of the neutral commit"
trusted_git -C "$optimized_directory" merge-base --is-ancestor "$optimized_base_commit" "$optimized_commit" || \
  die "optimized scope base is not an ancestor of the optimized commit"

[[ $output_input != *$'\n'* && $output_input != *$'\r'* ]] || die "output path contains a newline"
output_parent_input=$(dirname -- "$output_input")
output_name=$(basename -- "$output_input")
[[ -n $output_name && $output_name != . && $output_name != .. && $output_name != / ]] || die "invalid output directory: $output_input"
[[ -d $output_parent_input && ! -L $output_parent_input ]] || die "output parent must be a non-symlink directory: $output_parent_input"
output_parent=$(cd -- "$output_parent_input" && pwd -P)
output_directory="$output_parent/$output_name"
if output_parent_metadata=$(stat -f '%u %Lp' "$output_parent" 2>/dev/null); then
  :
else
  output_parent_metadata=$(stat -c '%u %a' "$output_parent")
fi
read -r output_parent_owner output_parent_mode <<<"$output_parent_metadata"
[[ $output_parent_owner == "$EUID" ]] || die "output parent must be owned by the current user"
output_parent_mode_value=$((8#$output_parent_mode))
(( (output_parent_mode_value & 0022) == 0 )) || die "output parent must not be group- or world-writable"
[[ ! -e $output_directory && ! -L $output_directory ]] || die "output directory must not already exist: $output_directory"

paths_overlap() {
  local left=$1
  local right=$2
  [[ $left == "$right" || $left == "$right/"* || $right == "$left/"* ]]
}

for input_directory in "$baseline_directory" "$aa_directory" "$optimized_directory"; do
  if paths_overlap "$output_directory" "$input_directory"; then
    die "output directory must not overlap an input checkout: $input_directory"
  fi
done

mkdir -m 0700 -- "$output_directory"
mkdir -m 0700 -- "$output_directory/controls" "$output_directory/adversarial" "$output_directory/measurements"
printf 'incomplete\n' >"$output_directory/status.txt"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-calibration.XXXXXX")
chmod 0700 "$temporary_directory"
completed=false
on_exit() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$temporary_directory" || true
  if [[ $completed == true ]]; then
    if [[ $release_parameters == true ]]; then
      printf 'complete\n' >"$output_directory/status.txt"
    else
      printf 'smoke-complete\n' >"$output_directory/status.txt"
    fi
  else
    printf 'failed exit=%s\n' "$exit_status" >"$output_directory/status.txt"
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' HUP INT TERM

# A neutral candidate is machine-checked, not merely labeled A/A. Its scope
# base must have the exact immutable baseline engine, and its candidate engine
# may differ only by one fixed ordinary trailing comment.
engine_path='internal/analyzer/engine.go'
baseline_engine="$temporary_directory/baseline-engine.go"
aa_base_engine="$temporary_directory/aa-base-engine.go"
optimized_base_engine="$temporary_directory/optimized-base-engine.go"
neutral_engine="$temporary_directory/neutral-engine.go"
expected_neutral_engine="$temporary_directory/expected-neutral-engine.go"
trusted_git -C "$baseline_directory" cat-file blob "$baseline_commit:$engine_path" >"$baseline_engine" || \
  die "immutable baseline engine blob is unavailable"
trusted_git -C "$aa_directory" cat-file blob "$aa_base_commit:$engine_path" >"$aa_base_engine" || \
  die "A/A scope-base engine blob is unavailable"
trusted_git -C "$optimized_directory" cat-file blob "$optimized_base_commit:$engine_path" >"$optimized_base_engine" || \
  die "optimized scope-base engine blob is unavailable"
cmp -s "$baseline_engine" "$aa_base_engine" || die "A/A scope-base engine differs from the immutable baseline"
cmp -s "$baseline_engine" "$optimized_base_engine" || die "optimized scope-base engine differs from the immutable baseline"
trusted_git -C "$aa_directory" cat-file blob "$aa_commit:$engine_path" >"$neutral_engine" || \
  die "neutral candidate engine blob is unavailable"
last_baseline_byte=$(tail -c 1 "$baseline_engine" | od -An -tu1 | tr -d '[:space:]')
[[ $last_baseline_byte == 10 ]] || die "immutable baseline engine must end with a newline"
cp "$baseline_engine" "$expected_neutral_engine"
printf '%s\n' '// streamlens-calibration-neutral' >>"$expected_neutral_engine"
cmp -s "$expected_neutral_engine" "$neutral_engine" || \
  die "neutral candidate engine must equal the immutable baseline plus the exact trailing comment: // streamlens-calibration-neutral"

started_at=$SECONDS
check_wall_bound() {
  local elapsed=$((SECONDS - started_at))
  ((elapsed <= max_wall_seconds)) || die "wall-clock bound exceeded: ${elapsed}s > ${max_wall_seconds}s"
}

run_control() {
  local name=$1
  local command_path=$2
  local log="$output_directory/controls/$name.log"

  [[ -f $command_path && ! -L $command_path ]] || die "required control is missing or unsafe: $command_path"
  if [[ $name == isolation ]]; then
    if ! REQUIRE_DOCKER_RUNTIME=1 env -u BASH_ENV -u ENV bash --noprofile --norc "$command_path" >"$log" 2>&1; then
      sed -n '1,160p' "$log" >&2
      die "$name control failed; see $log"
    fi
  elif ! env -u BASH_ENV -u ENV bash --noprofile --norc "$command_path" >"$log" 2>&1; then
    sed -n '1,160p' "$log" >&2
    die "$name control failed; see $log"
  fi
  check_wall_bound
}

run_reference_control() {
  local log="$output_directory/controls/reference.log"
  local cache="$temporary_directory/reference-cache"
  local mod_cache="$temporary_directory/reference-mod-cache"
  local go_tmp="$temporary_directory/reference-tmp"

  command -v go >/dev/null 2>&1 || die "go is required for the independent reference oracle"
  mkdir -m 0700 "$cache" "$mod_cache" "$go_tmp"
  if ! (
    cd -- "$baseline_directory"
    env -u BASH_ENV -u ENV \
      GOENV=off \
      GOCACHE="$cache" \
      GOMODCACHE="$mod_cache" \
      GOPROXY=off \
      GOSUMDB=off \
      GOTOOLCHAIN=local \
      GOTMPDIR="$go_tmp" \
      GOWORK=off \
      GOFLAGS='-mod=readonly -buildvcs=false' \
      go test -tags reference -run '^TestReferenceScenarioResults$' -count=1 -v ./internal/assessment
  ) >"$log" 2>&1; then
    sed -n '1,160p' "$log" >&2
    die "independent reference oracle failed; see $log"
  fi
  grep -Fq -- '--- PASS: TestReferenceScenarioResults' "$log" || \
    die "independent reference oracle did not execute its named test; see $log"
  check_wall_bound
}

# Reuse the focused guard suites. They own the symlink/special-file and fake
# Docker deadline/output-cap cases; calibration does not duplicate those tests.
run_control preparation "$script_directory/prepare-candidate-test.sh"
run_control scope "$script_directory/check-protected-test.sh"
run_reference_control
run_control isolation "$script_directory/isolation-test.sh"

create_canary_checkout() {
  local identifier=$1
  local engine_fixture=$2
  local mutation=$3
  local checkout="$temporary_directory/candidate-$identifier"
  local source="$fixture_directory/$engine_fixture"

  [[ $engine_fixture != */* && $engine_fixture == *.go ]] || die "invalid engine fixture name in canary manifest: $engine_fixture"
  [[ -f $source && ! -L $source ]] || die "canary engine fixture is missing or unsafe: $source"
  trusted_git -c protocol.file.allow=always clone --quiet --no-hardlinks --no-recurse-submodules "$baseline_directory" "$checkout"
  trusted_git -C "$checkout" checkout --quiet --detach "$baseline_commit"
  install -m 0644 "$source" "$checkout/internal/analyzer/engine.go"
  install -m 0644 "$fixture_directory/valid_optimization.md" "$checkout/OPTIMIZATION.md"
  trusted_git -C "$checkout" add -- internal/analyzer/engine.go OPTIMIZATION.md
  if [[ $mutation == protected ]]; then
    # Keep this blob distinct from every tracked calibration fixture. The scope
    # guard enables --find-copies-harder, so copying a fixture byte-for-byte would
    # exercise its earlier copy-change rejection instead of the protected-path
    # branch this canary is intended to prove.
    printf 'Protected-path calibration canary: %s; this file is never executed.\n' \
      "$identifier" >"$checkout/CALIBRATION_PROTECTED_CANARY.txt"
    chmod 0644 "$checkout/CALIBRATION_PROTECTED_CANARY.txt"
    trusted_git -C "$checkout" add -- CALIBRATION_PROTECTED_CANARY.txt
  elif [[ $mutation != none ]]; then
    die "unknown canary mutation in manifest: $mutation"
  fi
  trusted_git -C "$checkout" \
    -c core.hooksPath=/dev/null \
    -c user.name='StreamLens Calibration' \
    -c user.email='calibration@example.invalid' \
    commit --quiet -m "calibration canary: $identifier"
  printf '%s\n' "$checkout"
}

printf 'id\tphase\tstatus\tdiagnostic\n' >"$output_directory/adversarial/results.tsv"
while IFS=$'\t' read -r identifier phase engine_fixture mutation expected_diagnostic; do
  [[ -n $identifier ]] || continue
  [[ $identifier != \#* ]] || continue
  [[ $identifier =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid canary identifier: $identifier"
  [[ $phase == scope || $phase == functional ]] || die "invalid canary phase for $identifier: $phase"
  [[ -n $engine_fixture && -n $mutation && -n $expected_diagnostic ]] || die "incomplete canary manifest row: $identifier"

  canary_directory=$(create_canary_checkout "$identifier" "$engine_fixture" "$mutation")
  canary_commit=$(trusted_git -C "$canary_directory" rev-parse HEAD)
  canary_output="$output_directory/adversarial/$identifier-assessment"
  canary_log="$output_directory/adversarial/$identifier.log"
  set +e
  BENCH_SAMPLES="$samples" BENCH_TIME="$bench_time" BENCH_GOMAXPROCS=1 \
    env -u BASH_ENV -u ENV bash --noprofile --norc "$assess_script" \
      "$baseline_directory" "$canary_directory" \
      "$baseline_commit" "$baseline_commit" "$canary_commit" "$canary_output" >"$canary_log" 2>&1
  canary_status=$?
  set -e
  ((canary_status != 0)) || die "adversarial canary unexpectedly passed: $identifier"
  grep -Fq -- "$expected_diagnostic" "$canary_log" || {
    sed -n '1,160p' "$canary_log" >&2
    die "adversarial canary $identifier missed expected diagnostic: $expected_diagnostic"
  }
  if [[ $phase == scope ]]; then
    grep -Fq -- 'assess: protected-scope validation failed' "$canary_log" || die "canary $identifier did not fail in protected-scope validation"
  else
    grep -Fq -- 'assess: functional tests failed' "$canary_log" || die "canary $identifier did not fail in functional tests"
  fi
  if [[ -s $canary_output/benchmarks/baseline.txt || -s $canary_output/benchmarks/candidate.txt ]]; then
    die "adversarial canary reached benchmark sampling: $identifier"
  fi
  printf '%s\t%s\t%s\t%s\n' "$identifier" "$phase" "$canary_status" "$expected_diagnostic" >>"$output_directory/adversarial/results.tsv"
  check_wall_bound
done <"$fixture_manifest"

run_assessment() {
  local label=$1
  local candidate_directory=$2
  local candidate_base_commit=$3
  local candidate_commit=$4
  local run_output="$output_directory/measurements/$label"
  local log="$output_directory/measurements/$label.log"

  set +e
  BENCH_SAMPLES="$samples" BENCH_TIME="$bench_time" BENCH_GOMAXPROCS=1 \
    env -u BASH_ENV -u ENV bash --noprofile --norc "$assess_script" \
      "$baseline_directory" "$candidate_directory" \
      "$baseline_commit" "$candidate_base_commit" "$candidate_commit" "$run_output" >"$log" 2>&1
  assessment_status=$?
  set -e
  [[ -f $run_output/benchmarks/report.md ]] || {
    sed -n '1,160p' "$log" >&2
    die "$label assessment produced no benchmark report"
  }
  check_wall_bound
}

run_assessment aa "$aa_directory" "$aa_base_commit" "$aa_commit"
aa_status=$assessment_status
((aa_status == 0 || aa_status == 1)) || die "A/A assessment failed before a valid comparison (exit $aa_status)"
aa_report="$output_directory/measurements/aa/benchmarks/report.md"
aa_values="$output_directory/measurements/aa-improvements.tsv"
aa_geomean="$output_directory/measurements/aa-geomean.tsv"
awk -F '|' '
  function trim(value) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    return value
  }
  /^\| Scenario \| Metric / { in_scenarios = 1; next }
  /^## Geometric-mean result$/ {
    in_scenarios = 0
    in_geomean = 1
    next
  }
  in_scenarios {
    scenario = trim($2)
    metric = trim($3)
    value = trim($6)
    if (scenario != "---" && (metric == "ns/op" || metric == "B/op" || metric == "allocs/op")) {
      gsub(/^[+]/, "", value)
      gsub(/%$/, "", value)
      print "scenario\t" scenario "\t" metric "\t" value
    }
  }
  in_geomean && /^\| (ns\/op|B\/op|allocs\/op) / {
    metric = $2
    value = $3
    metric = trim(metric)
    value = trim(value)
    gsub(/^[+]/, "", value)
    gsub(/%$/, "", value)
    print "geomean\tall\t" metric "\t" value
  }
' "$aa_report" >"$aa_values"
scenario_value_count=$(awk -F '\t' '$1 == "scenario" { count++ } END { print count + 0 }' "$aa_values")
geomean_value_count=$(awk -F '\t' '$1 == "geomean" { count++ } END { print count + 0 }' "$aa_values")
[[ $scenario_value_count == 9 ]] || die "cannot parse all A/A scenario metrics"
[[ $geomean_value_count == 3 ]] || die "cannot parse all A/A geometric-mean metrics"
for expected_scenario in Balanced HighCardinality MostlyFiltered; do
  for expected_metric in ns/op B/op allocs/op; do
    expected_count=$(awk -F '\t' -v scenario="$expected_scenario" -v metric="$expected_metric" '
      $1 == "scenario" && $2 == scenario && $3 == metric { count++ }
      END { print count + 0 }
    ' "$aa_values")
    [[ $expected_count == 1 ]] || die "A/A report must contain exactly one $expected_scenario $expected_metric result"
  done
done
for expected_metric in ns/op B/op allocs/op; do
  expected_count=$(awk -F '\t' -v metric="$expected_metric" '
    $1 == "geomean" && $3 == metric { count++ }
    END { print count + 0 }
  ' "$aa_values")
  [[ $expected_count == 1 ]] || die "A/A report must contain exactly one $expected_metric geometric-mean result"
done
awk -F '\t' '$1 == "geomean" { print $3 "\t" $4 }' "$aa_values" >"$aa_geomean"

aa_max_observed=0
while IFS=$'\t' read -r value_scope value_name metric value; do
  [[ $value =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "invalid A/A improvement for $metric: $value"
  absolute_value=${value#-}
  if awk -v value="$absolute_value" -v maximum="$aa_max_abs_percent" 'BEGIN { exit !(value > maximum) }'; then
    die "A/A $value_scope $value_name $metric noise ${absolute_value}% exceeds ${aa_max_abs_percent}%"
  fi
  if awk -v value="$absolute_value" -v maximum="$aa_max_observed" 'BEGIN { exit !(value > maximum) }'; then
    aa_max_observed=$absolute_value
  fi
done <"$aa_values"

run_assessment optimized "$optimized_directory" "$optimized_base_commit" "$optimized_commit"
optimized_status=$assessment_status
((optimized_status == 0)) || die "known optimized assessment did not pass the performance gate (exit $optimized_status)"
optimized_report="$output_directory/measurements/optimized/benchmarks/report.md"
optimized_tier=$(awk '
  /^\*\*Overall optimization tier: / {
    value = $0
    sub(/^\*\*Overall optimization tier: /, "", value)
    sub(/\*\*$/, "", value)
    print value
  }
' "$optimized_report")
[[ -n $optimized_tier && $(printf '%s\n' "$optimized_tier" | wc -l | tr -d '[:space:]') == 1 ]] || die "cannot parse optimized overall tier"
case "$optimized_tier" in
  Below\ target|Middle|Senior|Staff) ;;
  *) die "invalid optimized overall tier: $optimized_tier" ;;
esac

tier_rank() {
  case "$1" in
    Below\ target) printf '0\n' ;;
    Middle) printf '1\n' ;;
    Senior) printf '2\n' ;;
    Staff) printf '3\n' ;;
    *) return 1 ;;
  esac
}
if (( $(tier_rank "$optimized_tier") < $(tier_rank "$optimized_min_tier") )); then
  die "optimized tier $optimized_tier is below required $optimized_min_tier"
fi
if (( $(tier_rank "$optimized_tier") > $(tier_rank "$optimized_max_tier") )); then
  die "optimized tier $optimized_tier is above allowed $optimized_max_tier"
fi

# Recheck the immutable inputs after every canary and measurement.
[[ $(physical_checkout "$baseline_directory" "baseline checkout" "$baseline_commit") == "$baseline_directory" ]] || die "baseline checkout identity changed"
[[ $(physical_checkout "$aa_directory" "A/A checkout" "$aa_commit") == "$aa_directory" ]] || die "A/A checkout identity changed"
[[ $(physical_checkout "$optimized_directory" "optimized checkout" "$optimized_commit") == "$optimized_directory" ]] || die "optimized checkout identity changed"

elapsed_seconds=$((SECONDS - started_at))
if [[ $release_parameters == true ]]; then
  calibration_mode='release'
else
  calibration_mode='smoke (not release evidence)'
fi
cat >"$output_directory/calibration-summary.md" <<EOF
# StreamLens calibration result

- Calibration mode: $calibration_mode
- Baseline commit: \`$baseline_commit\`
- Neutral A/A scope base: \`$aa_base_commit\`
- Neutral A/A commit: \`$aa_commit\`
- Known optimized scope base: \`$optimized_base_commit\`
- Known optimized commit: \`$optimized_commit\`
- Benchmark samples: $samples
- Benchmark time: \`$bench_time\`
- A/A maximum absolute reported change: ${aa_max_observed}% (limit ${aa_max_abs_percent}%)
- Optimized tier: $optimized_tier (expected $optimized_min_tier through $optimized_max_tier)
- Adversarial canaries: all rejected before benchmark scoring
- Wall time: ${elapsed_seconds}s (limit ${max_wall_seconds}s)
EOF

completed=true
if [[ $release_parameters == true ]]; then
  echo "release calibration passed; evidence: $output_directory"
else
  echo "smoke calibration passed (not release evidence); output: $output_directory"
fi
