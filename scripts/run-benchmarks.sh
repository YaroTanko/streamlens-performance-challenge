#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage:
  $0 <baseline-directory> <candidate-directory> <output-directory>
  $0 --isolated-runner <trusted-runner> <baseline-directory> <candidate-directory> <output-directory>
USAGE
  exit 2
}

isolated_runner=
if [[ ${1:-} == "--isolated-runner" ]]; then
  [[ $# -eq 5 ]] || usage
  runner_input=$2
  [[ $runner_input == /* ]] || {
    echo "isolated runner must be an absolute path" >&2
    exit 2
  }
  [[ -f $runner_input && ! -L $runner_input ]] || {
    echo "isolated runner must be a regular non-symbolic-link file: $runner_input" >&2
    exit 2
  }
  isolated_runner=$(cd -- "$(dirname -- "$runner_input")" && pwd -P)/$(basename -- "$runner_input")
  shift 2
fi

[[ $# -eq 3 ]] || usage

baseline_directory=$(cd "$1" && pwd)
candidate_directory=$(cd "$2" && pwd)
output_directory=$3
samples=${BENCH_SAMPLES:-7}
bench_time=${BENCH_TIME:-300ms}
gomaxprocs=${BENCH_GOMAXPROCS:-1}
marker_token="$$.$RANDOM"

if ! [[ $samples =~ ^[0-9]+$ ]] || ((samples < 5)); then
  echo "BENCH_SAMPLES must be an integer greater than or equal to 5" >&2
  exit 2
fi

mkdir -p "$output_directory"
baseline_output="$output_directory/baseline.txt"
candidate_output="$output_directory/candidate.txt"
# Remove only files owned by previous invocations of this runner.
rm -f \
  "$output_directory"/baseline-sample-*.tmp \
  "$output_directory"/baseline-sample-*-failed.txt \
  "$output_directory"/candidate-sample-*.tmp \
  "$output_directory"/candidate-sample-*-failed.txt
: >"$baseline_output"
: >"$candidate_output"

{
  printf 'host_go_version=%s\n' "$(go version)"
  if [[ -n $isolated_runner ]]; then
    echo "execution=isolated"
    echo "container_image=${ASSESSMENT_DOCKER_IMAGE:-unset}"
  else
    echo "execution=direct"
  fi
  echo "samples=$samples"
  echo "benchtime=$bench_time"
  echo "GOMAXPROCS=$gomaxprocs"
} >"$output_directory/environment.txt"

run_sample() {
  local directory=$1
  local output=$2
  local sample=$3

  local sample_output
  local failed_output
  local status
  local -a benchmark_command
  sample_output="${output%.txt}-sample-${sample}.tmp"
  failed_output="${output%.txt}-sample-${sample}-failed.txt"
  rm -f "$sample_output" "$failed_output"

  if [[ -n $isolated_runner ]]; then
    benchmark_command=(
      bash --noprofile --norc "$isolated_runner"
      "$directory" benchmark "$bench_time" "$gomaxprocs"
    )
  else
    benchmark_command=(
      go test ./internal/assessment
      -run '^$'
      -bench '^BenchmarkAnalyze$'
      -benchmem
      -benchtime "$bench_time"
      -count 1
      -cpu "$gomaxprocs"
      -timeout 5m
    )
  fi

  if [[ -n $isolated_runner ]]; then
    if "${benchmark_command[@]}" >"$sample_output" 2>&1; then
      status=0
    else
      status=$?
    fi
  else
    if (
      cd "$directory"
      GOMAXPROCS="$gomaxprocs" "${benchmark_command[@]}"
    ) >"$sample_output" 2>&1; then
      status=0
    else
      status=$?
    fi
  fi
  if [[ $status -eq 0 ]]; then
    :
  else
    mv "$sample_output" "$failed_output"
    echo "benchmark sample failed: directory=$directory sample=$sample" >&2
    cat "$failed_output" >&2
    return "$status"
  fi

  {
    printf '@@BENCHCOMPARE SAMPLE BEGIN %s %s\n' "$sample" "$marker_token"
    # Prefix captured output so it cannot inject trusted framing markers.
    sed 's/^/| /' "$sample_output"
    printf '@@BENCHCOMPARE SAMPLE END %s %s\n' "$sample" "$marker_token"
  } >>"$output"
  rm -f "$sample_output"
}

for ((sample = 1; sample <= samples; sample++)); do
  if ((sample % 2 == 1)); then
    run_sample "$baseline_directory" "$baseline_output" "$sample"
    run_sample "$candidate_directory" "$candidate_output" "$sample"
  else
    run_sample "$candidate_directory" "$candidate_output" "$sample"
    run_sample "$baseline_directory" "$baseline_output" "$sample"
  fi
done
