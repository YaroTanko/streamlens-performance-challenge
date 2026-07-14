#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <baseline-directory> <candidate-directory> <output-directory>" >&2
  exit 2
fi

baseline_directory=$(cd "$1" && pwd)
candidate_directory=$(cd "$2" && pwd)
output_directory=$3
samples=${BENCH_SAMPLES:-7}
bench_time=${BENCH_TIME:-300ms}
gomaxprocs=${BENCH_GOMAXPROCS:-1}

if ! [[ $samples =~ ^[0-9]+$ ]] || ((samples < 5)); then
  echo "BENCH_SAMPLES must be an integer greater than or equal to 5" >&2
  exit 2
fi

mkdir -p "$output_directory"
baseline_output="$output_directory/baseline.txt"
candidate_output="$output_directory/candidate.txt"
: >"$baseline_output"
: >"$candidate_output"

{
  go version
  echo "samples=$samples"
  echo "benchtime=$bench_time"
  echo "GOMAXPROCS=$gomaxprocs"
} >"$output_directory/environment.txt"

run_sample() {
  local directory=$1
  local output=$2
  local sample=$3

  echo "### sample $sample" >>"$output"
  (
    cd "$directory"
    GOMAXPROCS="$gomaxprocs" go test ./internal/assessment \
      -run '^$' \
      -bench '^BenchmarkAnalyze$' \
      -benchmem \
      -benchtime "$bench_time" \
      -count 1 \
      -cpu "$gomaxprocs" \
      -timeout 5m
  ) >>"$output" 2>&1
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
