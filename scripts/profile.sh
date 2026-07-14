#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <cpu|alloc|all> [scenario] [output-directory]" >&2
  echo "scenarios: Balanced, HighCardinality, MostlyFiltered" >&2
}

if (( $# < 1 || $# > 3 )); then
  usage
  exit 2
fi

mode=$1
scenario=${2:-${PROFILE_SCENARIO:-Balanced}}
profile_time=${PROFILE_TIME:-2s}

case "$mode" in
  cpu|alloc|all)
    ;;
  *)
    echo "invalid profiling mode: $mode" >&2
    usage
    exit 2
    ;;
esac

case "$scenario" in
  Balanced|HighCardinality|MostlyFiltered)
    ;;
  *)
    echo "invalid profiling scenario: $scenario" >&2
    usage
    exit 2
    ;;
esac

if [[ -z $profile_time ]]; then
  echo "PROFILE_TIME must not be empty" >&2
  exit 2
fi

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
default_project_directory=$(cd "$script_directory/.." && pwd)
project_directory_input=${PROFILE_PROJECT_DIRECTORY:-$default_project_directory}

if [[ ! -d $project_directory_input ]]; then
  echo "project directory does not exist: $project_directory_input" >&2
  exit 2
fi

project_directory=$(cd "$project_directory_input" && pwd)
if [[ ! -f $project_directory/go.mod ]]; then
  echo "project directory does not contain go.mod: $project_directory" >&2
  exit 2
fi

output_directory_input=${3:-$project_directory/.bench/profiles}
if [[ -z $output_directory_input ]]; then
  echo "output directory must not be empty" >&2
  exit 2
fi

case "$output_directory_input" in
  /*)
    ;;
  *)
    output_directory_input=$project_directory/$output_directory_input
    ;;
esac

mkdir -p "$output_directory_input"
output_directory=$(cd "$output_directory_input" && pwd)

benchmark_pattern="^BenchmarkAnalyze$/^${scenario}$"
test_binary=$output_directory/assessment.test
cpu_profile=$output_directory/cpu.pprof
alloc_profile=$output_directory/alloc.pprof
cpu_top=$output_directory/cpu-top.txt
alloc_top=$output_directory/alloc-top.txt

run_cpu_profile() {
  echo "Profiling CPU: BenchmarkAnalyze/$scenario for $profile_time"
  (
    cd "$project_directory"
    GOMAXPROCS=1 go test -o "$test_binary" ./internal/assessment \
      -run '^$' \
      -bench "$benchmark_pattern" \
      -benchtime "$profile_time" \
      -count 1 \
      -cpu 1 \
      -timeout 5m \
      -cpuprofile "$cpu_profile"
  )

  go tool pprof -top -nodecount=20 "$test_binary" "$cpu_profile" >"$cpu_top"
  echo "CPU profile: $cpu_profile"
  echo "CPU top report: $cpu_top"
  cat "$cpu_top"
}

run_alloc_profile() {
  echo "Profiling allocations: BenchmarkAnalyze/$scenario for $profile_time"
  (
    cd "$project_directory"
    GOMAXPROCS=1 go test -o "$test_binary" ./internal/assessment \
      -run '^$' \
      -bench "$benchmark_pattern" \
      -benchtime "$profile_time" \
      -count 1 \
      -cpu 1 \
      -timeout 5m \
      -memprofile "$alloc_profile"
  )

  go tool pprof -top -nodecount=20 -sample_index=alloc_space \
    "$test_binary" "$alloc_profile" >"$alloc_top"
  echo "Allocation profile (alloc_space): $alloc_profile"
  echo "Allocation top report: $alloc_top"
  cat "$alloc_top"
}

case "$mode" in
  cpu)
    run_cpu_profile
    ;;
  alloc)
    run_alloc_profile
    ;;
  all)
    run_cpu_profile
    run_alloc_profile
    ;;
esac

echo "Retained test binary: $test_binary"
