#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: $0 <baseline-checkout> <candidate-checkout> <baseline-commit> <candidate-base-commit> <candidate-commit> <new-output-directory>

ASSESSMENT_DOCKER_IMAGE must be an immutable name@sha256:<64 lowercase hex> reference.
USAGE
  exit 2
}

die() {
  echo "assess: $*" >&2
  exit 2
}

# Read-only Git inspection must not execute repository-local fsmonitor commands
# or inherit caller-controlled repository/config/trace plumbing.
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

[[ $# -eq 6 ]] || usage

baseline_input=$1
candidate_input=$2
baseline_commit=$3
candidate_base_commit=$4
candidate_commit=$5
output_input=$6

for input in "$baseline_input" "$candidate_input" "$output_input"; do
  [[ $input != *$'\n'* && $input != *$'\r'* ]] || die "paths containing newlines are not supported"
done
for revision in "$baseline_commit" "$candidate_base_commit" "$candidate_commit"; do
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || die "revisions must be full 40-character lowercase Git SHAs"
done

physical_checkout() {
  local input=$1
  local label=$2

  [[ -d $input && ! -L $input ]] || die "$label must be a non-symbolic-link directory: $input"
  local directory
  directory=$(cd -- "$input" && pwd -P)
  trusted_git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$label is not a Git checkout: $input"
  printf '%s\n' "$directory"
}

validate_checkout() {
  local directory=$1
  local expected_commit=$2
  local label=$3
  local actual_commit
  local index_entries
  local index_entry
  local status_output

  trusted_git -C "$directory" cat-file -e "$expected_commit^{commit}" 2>/dev/null || die "$label does not contain commit $expected_commit"
  actual_commit=$(trusted_git -C "$directory" rev-parse --verify 'HEAD^{commit}')
  [[ $actual_commit == "$expected_commit" ]] || die "$label HEAD is $actual_commit, expected $expected_commit"
  status_output=$(trusted_git -C "$directory" -c core.quotePath=true status \
    --porcelain=v1 --untracked-files=all --ignored=matching)
  [[ -z $status_output ]] || die "$label must be a pristine checkout without modified, untracked, or ignored files"
  index_entries=$(trusted_git -C "$directory" -c core.quotePath=true ls-files -v) || die "could not inspect $label index flags"
  while IFS= read -r index_entry; do
    [[ -z $index_entry || $index_entry == "H "* ]] || die "$label uses unsupported assume-unchanged or skip-worktree index flags"
  done <<<"$index_entries"
}

require_trusted_file() {
  local path=$1
  [[ -f $path && ! -L $path ]] || die "trusted baseline file must be a regular non-symbolic-link file: $path"
}

paths_overlap() {
  local left=$1
  local right=$2
  [[ $left == "$right" || $left == "$right/"* || $right == "$left/"* ]]
}

directory_owner_and_mode() {
  local directory=$1
  if stat -f '%u %Lp' "$directory" >/dev/null 2>&1; then
    stat -f '%u %Lp' "$directory"
  else
    stat -c '%u %a' "$directory"
  fi
}

baseline_directory=$(physical_checkout "$baseline_input" "baseline checkout")
candidate_directory=$(physical_checkout "$candidate_input" "candidate checkout")
validate_checkout "$baseline_directory" "$baseline_commit" "baseline checkout"
validate_checkout "$candidate_directory" "$candidate_commit" "candidate checkout"
trusted_git -C "$candidate_directory" cat-file -e "$candidate_base_commit^{commit}" 2>/dev/null || die "candidate checkout does not contain base commit $candidate_base_commit"

assessment_image=${ASSESSMENT_DOCKER_IMAGE:-}
if [[ $assessment_image != *@sha256:* ]]; then
  die "ASSESSMENT_DOCKER_IMAGE must use an immutable @sha256 digest"
fi
image_name=${assessment_image%@sha256:*}
image_digest=${assessment_image##*@sha256:}
[[ $image_name =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ && $image_digest =~ ^[0-9a-f]{64}$ ]] || die "invalid digest-pinned Docker image reference"

samples=${BENCH_SAMPLES:-7}
bench_time=${BENCH_TIME:-300ms}
gomaxprocs=${BENCH_GOMAXPROCS:-1}
profile_scenario=${PROFILE_SCENARIO:-Balanced}
profile_time=${PROFILE_TIME:-2s}
if ! [[ $samples =~ ^[0-9]+$ ]] || ((samples < 5)); then
  die "BENCH_SAMPLES must be an integer greater than or equal to 5"
fi
[[ $bench_time =~ ^([1-9][0-9]*x|[0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))$ ]] || die "invalid BENCH_TIME: $bench_time"
[[ $gomaxprocs == 1 ]] || die "authoritative BENCH_GOMAXPROCS must be 1"
case "$profile_scenario" in
  Balanced | HighCardinality | MostlyFiltered) ;;
  *) die "invalid PROFILE_SCENARIO: $profile_scenario" ;;
esac
[[ $profile_time =~ ^([0-9]+([.][0-9]+)?)(ms|s|m)$ ]] || die "invalid PROFILE_TIME: $profile_time"
profile_time_value=${BASH_REMATCH[1]}
[[ $profile_time_value =~ [1-9] ]] || die "PROFILE_TIME must be greater than zero"

trusted_check="$baseline_directory/scripts/check-protected.sh"
trusted_prepare="$baseline_directory/scripts/prepare-candidate.sh"
trusted_isolated_runner="$baseline_directory/scripts/run-isolated.sh"
trusted_benchmark_runner="$baseline_directory/scripts/run-benchmarks.sh"
for trusted_file in \
  "$trusted_check" \
  "$trusted_prepare" \
  "$trusted_isolated_runner" \
  "$trusted_benchmark_runner" \
  "$baseline_directory/go.mod"; do
  require_trusted_file "$trusted_file"
done
[[ -d $baseline_directory/cmd/benchcompare && ! -L $baseline_directory/cmd/benchcompare ]] || die "trusted benchcompare source is missing"
[[ -d $baseline_directory/cmd/evidencemanifest && ! -L $baseline_directory/cmd/evidencemanifest ]] || die "trusted evidencemanifest source is missing"

output_parent_input=$(dirname -- "$output_input")
output_name=$(basename -- "$output_input")
[[ -n $output_name && $output_name != . && $output_name != .. && $output_name != / ]] || die "invalid output directory: $output_input"
[[ -d $output_parent_input && ! -L $output_parent_input ]] || die "output parent must be a non-symbolic-link directory: $output_parent_input"
output_parent=$(cd -- "$output_parent_input" && pwd -P)
output_directory="$output_parent/$output_name"
read -r output_parent_owner output_parent_mode < <(directory_owner_and_mode "$output_parent")
[[ $output_parent_owner == "$EUID" ]] || die "output parent must be owned by the current user"
output_parent_mode_value=$((8#$output_parent_mode))
(( (output_parent_mode_value & 0022) == 0 )) || die "output parent must not be group- or world-writable"
[[ ! -e $output_directory && ! -L $output_directory ]] || die "output directory must not already exist: $output_input"
paths_overlap "$output_directory" "$baseline_directory" && die "output directory overlaps the baseline checkout"
paths_overlap "$output_directory" "$candidate_directory" && die "output directory overlaps the candidate checkout"

umask 077
mkdir -m 0700 -- "$output_directory" || die "could not create output directory: $output_input"

set +e
(
  cd -- "$candidate_directory"
  env -u BASH_ENV -u ENV bash --noprofile --norc "$trusted_check" "$candidate_base_commit" "$candidate_commit"
)
scope_status=$?
set -e
if [[ $scope_status -ne 0 ]]; then
  echo "assess: protected-scope validation failed (exit $scope_status)" >&2
  exit "$scope_status"
fi

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-assess.XXXXXX")
chmod 0700 "$work_directory"
work_directory=$(cd -- "$work_directory" && pwd -P)
# shellcheck disable=SC2329 # Invoked by traps.
cleanup() {
  rm -rf -- "$work_directory"
}
trap cleanup EXIT HUP INT TERM

prepared_baseline="$work_directory/prepared-baseline"
prepared_candidate="$work_directory/prepared-candidate"
tool_directory="$work_directory/tools"
go_cache="$work_directory/go-cache"
go_tmp="$work_directory/go-tmp"
go_mod_cache="$work_directory/go-mod-cache"
mkdir -m 0700 "$tool_directory" "$go_cache" "$go_tmp" "$go_mod_cache"

run_prepare() {
  local overlay=$1
  local destination=$2
  local label=$3
  local status

  set +e
  env -u BASH_ENV -u ENV bash --noprofile --norc \
    "$trusted_prepare" "$baseline_directory" "$overlay" "$destination"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "assess: $label preparation failed (exit $status)" >&2
    exit "$status"
  fi
}

# Both inputs are materialized through the same trusted overlay mechanism.
run_prepare "$baseline_directory" "$prepared_baseline" "baseline"
run_prepare "$candidate_directory" "$prepared_candidate" "candidate"

trusted_go_env=(
  GOENV=off
  GOCACHE="$go_cache"
  GOMODCACHE="$go_mod_cache"
  GOPROXY=off
  GOSUMDB=off
  GOTOOLCHAIN=local
  GOTMPDIR="$go_tmp"
  GOWORK=off
  "GOFLAGS=-mod=readonly -buildvcs=false"
)

if ! (
  cd -- "$baseline_directory"
  env "${trusted_go_env[@]}" go build -o "$tool_directory/benchcompare" ./cmd/benchcompare
  env "${trusted_go_env[@]}" go build -o "$tool_directory/evidencemanifest" ./cmd/evidencemanifest
); then
  die "could not build trusted assessment tools"
fi

functional_output="$output_directory/functional.txt"
set +e
env -u BASH_ENV -u ENV bash --noprofile --norc \
  "$trusted_isolated_runner" "$prepared_candidate" test >"$functional_output" 2>&1
test_status=$?
set -e
if [[ $test_status -ne 0 ]]; then
  echo "assess: functional tests failed (exit $test_status); inspect $functional_output" >&2
  exit "$test_status"
fi

benchmark_directory="$output_directory/benchmarks"
set +e
BENCH_SAMPLES="$samples" \
BENCH_TIME="$bench_time" \
BENCH_GOMAXPROCS="$gomaxprocs" \
env -u BASH_ENV -u ENV bash --noprofile --norc \
  "$trusted_benchmark_runner" \
  --isolated-runner "$trusted_isolated_runner" \
  "$prepared_baseline" "$prepared_candidate" "$benchmark_directory"
benchmark_status=$?
set -e
if [[ $benchmark_status -ne 0 ]]; then
  echo "assess: benchmark sampling failed (exit $benchmark_status)" >&2
  exit "$benchmark_status"
fi

report_path="$benchmark_directory/report.md"
set +e
"$tool_directory/benchcompare" \
  -baseline "$benchmark_directory/baseline.txt" \
  -candidate "$benchmark_directory/candidate.txt" \
  -output "$report_path" \
  -min-samples "$samples"
comparator_status=$?
set -e
case "$comparator_status" in
  0 | 1 | 2) ;;
  *)
    echo "assess: comparator terminated with unexpected exit $comparator_status" >&2
    comparator_status=2
    ;;
esac
if [[ ! -e $report_path ]]; then
  printf '# Benchmark comparison\n\n❌ Comparison failed before a report was produced.\n' >"$report_path"
  comparator_status=2
elif [[ ! -f $report_path || -L $report_path ]]; then
  echo "assess: comparator report is not a regular file" >&2
  exit 2
fi

profile_directory="$output_directory/profiles"
profile_output="$output_directory/profile.txt"
set +e
env -u BASH_ENV -u ENV bash --noprofile --norc \
  "$trusted_isolated_runner" \
  "$prepared_candidate" profile "$profile_scenario" "$profile_time" "$profile_directory" \
  >"$profile_output" 2>&1
profile_status=$?
set -e
if [[ $profile_status -eq 0 ]]; then
  profile_evidence_status=captured
else
  profile_evidence_status="failed-exit-$profile_status"
fi

host_go_version=$(cd -- "$baseline_directory" && env "${trusted_go_env[@]}" go env GOVERSION)
host_go_os=$(cd -- "$baseline_directory" && env "${trusted_go_env[@]}" go env GOOS)
host_go_arch=$(cd -- "$baseline_directory" && env "${trusted_go_env[@]}" go env GOARCH)
runner_os=$(uname -s)
runner_arch=$(uname -m)

manifest_arguments=(
  -root "$output_directory"
  -output-dir "$output_directory/evidence"
  -revision "assessment_baseline=$baseline_commit"
  -revision "candidate_base=$candidate_base_commit"
  -revision "candidate=$candidate_commit"
  -parameter "benchmark.samples=$samples"
  -parameter "benchmark.time=$bench_time"
  -parameter "benchmark.gomaxprocs=$gomaxprocs"
  -parameter "profile.status=$profile_evidence_status"
  -parameter "profile.scenario=$profile_scenario"
  -parameter "profile.time=$profile_time"
  -parameter "profile.gomaxprocs=1"
  -environment "container.image=$assessment_image"
  -environment "host.go.version=$host_go_version"
  -environment "host.go.os=$host_go_os"
  -environment "host.go.arch=$host_go_arch"
  -artifact "functional.output=functional.txt"
  -artifact "baseline.samples=benchmarks/baseline.txt"
  -artifact "candidate.samples=benchmarks/candidate.txt"
  -artifact "benchmark.environment=benchmarks/environment.txt"
  -artifact "comparison.report=benchmarks/report.md"
  -artifact "profile.output=profile.txt"
  -runner "host.os=$runner_os"
  -runner "host.arch=$runner_arch"
  -runner "github.image_os=${ImageOS:-local}"
  -runner "github.image_version=${ImageVersion:-local}"
)
if [[ $profile_status -eq 0 ]]; then
  manifest_arguments+=(
    -artifact "profile.binary=profiles/assessment.test"
    -artifact "profile.cpu=profiles/cpu.pprof"
    -artifact "profile.alloc=profiles/alloc.pprof"
    -artifact "profile.cpu_top=profiles/cpu-top.txt"
    -artifact "profile.alloc_top=profiles/alloc-top.txt"
  )
fi

manifest_status=0
"$tool_directory/evidencemanifest" "${manifest_arguments[@]}" || manifest_status=$?
if [[ $manifest_status -ne 0 ]]; then
  echo "assess: evidence manifest failed (exit $manifest_status)" >&2
  exit 2
fi

if [[ $profile_status -ne 0 ]]; then
  echo "assess: isolated profile capture failed (exit $profile_status); inspect $profile_output" >&2
  exit 2
fi
echo "assess: isolated profile artifacts captured for $profile_scenario"
exit "$comparator_status"
