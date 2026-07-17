#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fixture_directory="$script_directory/testdata/prepare-candidate/isolation"
runner="$script_directory/run-isolated.sh"
configured_image=${ASSESSMENT_DOCKER_IMAGE:-}
construction_image=${configured_image:-example.invalid/streamlens-go@sha256:0000000000000000000000000000000000000000000000000000000000000000}
require_runtime=${REQUIRE_DOCKER_RUNTIME:-0}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-isolation-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "isolation-test: $*" >&2
  exit 1
}

assert_contains() {
  local output=$1
  local expected=$2
  [[ $output == *"$expected"* ]] || fail "command is missing: $expected"
}

[[ $require_runtime == 0 || $require_runtime == 1 ]] || fail "REQUIRE_DOCKER_RUNTIME must be 0 or 1"

test_command=$(ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" test)
for required in \
  "--read-only" \
  "--network=none" \
  "--ipc=none" \
  "--cap-drop=ALL" \
  "--security-opt=no-new-privileges:true" \
  "--user=65532:65532" \
  "--pull=never" \
  "--entrypoint=/bin/sh" \
  "--log-driver=none" \
  "--ulimit=core=0:0" \
  "tmpfs=/tmp:rw\\,nosuid\\,nodev\\,exec" \
  "--cidfile=" \
  "target=/workspace\\,readonly" \
  "GOPROXY=off" \
  "GOTOOLCHAIN=local" \
  "GOWORK=off" \
  "GOENV=off" \
  "HTTP_PROXY=" \
  "HTTPS_PROXY=" \
  "ALL_PROXY=" \
  "NO_PROXY=" \
  "http_proxy=" \
  "https_proxy=" \
  "all_proxy=" \
  "no_proxy=" \
  "GOMAXPROCS=2" \
  "--cpus=2" \
  "ulimit -S -f" \
  "watchdog: sleep 360" \
  "emit at most 8388608 bytes" \
  "docker rm -f -v CID" \
  "attempts=2"; do
  assert_contains "$test_command" "$required"
done

mount_count=$(grep -o -- '--mount' <<<"$test_command" | wc -l | tr -d '[:space:]')
[[ $mount_count == 1 ]] || fail "expected exactly one host bind mount, got $mount_count"
[[ $test_command != *"--privileged"* ]] || fail "command unexpectedly enables privileged mode"
[[ $test_command != *"--name="* ]] || fail "command unexpectedly uses a name-based cleanup target"
[[ $test_command != *"--kill-after"* ]] || fail "command unexpectedly depends on GNU timeout"
[[ $test_command != *"/results"* ]] || fail "command unexpectedly mounts or references a results directory"

benchmark_command=$(ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" benchmark 1x)
assert_contains "$benchmark_command" "-benchtime"
assert_contains "$benchmark_command" "1x"
assert_contains "$benchmark_command" "GOMAXPROCS=1"
assert_contains "$benchmark_command" "--cpus=1"

profile_parent="$temporary_directory/profile-parent"
mkdir -m 0700 "$profile_parent"
profile_command=$(ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command \
  "$fixture_directory" profile Balanced 1s "$profile_parent/profiles")
assert_contains "$profile_command" "BenchmarkAnalyze"
assert_contains "$profile_command" "Balanced"
assert_contains "$profile_command" "cpu.pprof"
assert_contains "$profile_command" "alloc.pprof"
assert_contains "$profile_command" "docker exec validated-CID /bin/cat each fixed artifact"
assert_contains "$profile_command" "validate exact artifacts"
assert_contains "$profile_command" "docker stop validated-CID"
profile_mount_count=$(grep -o -- '--mount' <<<"$profile_command" | wc -l | tr -d '[:space:]')
[[ $profile_mount_count == 1 ]] || fail "profile command unexpectedly exposes a host results mount"
[[ $profile_command != *"$profile_parent/profiles"* ]] || fail "profile output path leaked into the container command"

if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" profile Unknown 1s "$profile_parent/invalid-scenario" >/dev/null 2>&1; then
  fail "invalid profiling scenario was accepted"
fi
if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" profile Balanced 0s "$profile_parent/invalid-time" >/dev/null 2>&1; then
  fail "zero profiling time was accepted"
fi
if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" profile Balanced 00.000s "$profile_parent/invalid-decimal-time" >/dev/null 2>&1; then
  fail "zero decimal profiling time was accepted"
fi
if ASSESSMENT_DOCKER_CONTROL_DEADLINE_SECONDS=0 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" profile Balanced 1s "$profile_parent/invalid-control-deadline" >/dev/null 2>&1; then
  fail "zero Docker control deadline was accepted"
fi

if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" benchmark invalid 1 >/dev/null 2>&1; then
  fail "invalid benchmark time was accepted"
fi
if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" benchmark 1x 2 >/dev/null 2>&1; then
  fail "non-authoritative benchmark GOMAXPROCS was accepted"
fi
if BENCH_GOMAXPROCS=2 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" benchmark 1x >/dev/null 2>&1; then
  fail "non-authoritative benchmark GOMAXPROCS environment was accepted"
fi
if ASSESSMENT_TEST_GOMAXPROCS=9 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" test >/dev/null 2>&1; then
  fail "unsafe functional-test CPU count was accepted"
fi
short_policy=$(ASSESSMENT_DOCKER_DEADLINE_SECONDS=2 ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES=4096 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" test)
assert_contains "$short_policy" "watchdog: sleep 2"
assert_contains "$short_policy" "emit at most 4096 bytes"
assert_contains "$short_policy" "ulimit -S -f 68"
if ASSESSMENT_DOCKER_DEADLINE_SECONDS=0 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" test >/dev/null 2>&1; then
  fail "zero host deadline was accepted"
fi
if ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES=1024 ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$fixture_directory" test >/dev/null 2>&1; then
  fail "unsafe output cap was accepted"
fi
if ASSESSMENT_DOCKER_IMAGE="golang:1.26.5-bookworm" bash "$runner" --print-command "$fixture_directory" test >/dev/null 2>&1; then
  fail "mutable Docker image tag was accepted"
fi
if env -u ASSESSMENT_DOCKER_IMAGE bash "$runner" --print-command "$fixture_directory" test >/dev/null 2>&1; then
  fail "missing Docker image digest was accepted"
fi

mkdir -p "$temporary_directory/with,comma"
cp -a "$fixture_directory" "$temporary_directory/with,comma/prepared"
ln -s "with,comma" "$temporary_directory/canonical-parent"
if output=$(ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command "$temporary_directory/canonical-parent/prepared" test 2>&1); then
  fail "comma in canonical prepared path was accepted"
fi
[[ $output == *"canonical prepared path"* ]] || fail "canonical comma path reported unexpected error: $output"

fake_bin="$temporary_directory/fake-bin"
fake_tmp="$temporary_directory/fake-runtime"
fake_log="$temporary_directory/fake-docker.log"
fake_state="$temporary_directory/fake-docker-state"
mkdir -m 0700 "$fake_bin" "$fake_tmp"
mkdir -m 0700 "$fake_state"
cp "$fixture_directory/../fake-docker.sh" "$fake_bin/docker"
chmod 0755 "$fake_bin/docker"
expected_cid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

run_fake() {
  local mode=$1
  local cleanup_mode=$2
  local deadline=$3
  local cap=$4
  rm -f -- "$fake_state/stopped"
  PATH="$fake_bin:$PATH" \
    TMPDIR="$fake_tmp" \
    FAKE_DOCKER_LOG="$fake_log" \
    FAKE_DOCKER_MODE="$mode" \
    FAKE_DOCKER_CLEANUP_MODE="$cleanup_mode" \
    FAKE_DOCKER_STATE="$fake_state" \
    ASSESSMENT_DOCKER_DEADLINE_SECONDS="$deadline" \
    ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES="$cap" \
    ASSESSMENT_DOCKER_IMAGE="$construction_image" \
    bash "$runner" "$fixture_directory" test
}

run_fake_profile() {
  local output=$1
  local copy_mode=$2
  local cleanup_mode=$3
  local stop_mode=${4:-success}
  local control_deadline=${5:-2}
  rm -f -- "$fake_state/stopped"
  PATH="$fake_bin:$PATH" \
    TMPDIR="$fake_tmp" \
    FAKE_DOCKER_LOG="$fake_log" \
    FAKE_DOCKER_MODE=profile \
    FAKE_DOCKER_COPY_MODE="$copy_mode" \
    FAKE_DOCKER_CLEANUP_MODE="$cleanup_mode" \
    FAKE_DOCKER_STOP_MODE="$stop_mode" \
    FAKE_DOCKER_STATE="$fake_state" \
    ASSESSMENT_DOCKER_DEADLINE_SECONDS=10 \
    ASSESSMENT_DOCKER_CONTROL_DEADLINE_SECONDS="$control_deadline" \
    ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES=4096 \
    ASSESSMENT_DOCKER_IMAGE="$construction_image" \
    bash "$runner" "$fixture_directory" profile Balanced 1s "$output"
}

assert_safe_cleanup() {
  local label=$1
  grep -q "^rm cid=$expected_cid$" "$fake_log" || fail "$label did not clean up by validated CID"
  if grep -q '^unsafe-rm ' "$fake_log"; then
    fail "$label attempted unsafe container cleanup"
  fi
}

: >"$fake_log"
success_start=$SECONDS
fake_output=$(run_fake success success 360 4096)
success_elapsed=$((SECONDS - success_start))
[[ $fake_output == *"fake docker success canary"* ]] || fail "fake Docker success output was lost: $fake_output"
((success_elapsed < 3)) || fail "successful fake Docker retained a default-deadline timer for ${success_elapsed}s"
assert_safe_cleanup "success path"

: >"$fake_log"
set +e
fake_output=$(run_fake hang success 1 4096 2>&1)
fake_status=$?
set -e
((fake_status != 0)) || fail "hung fake Docker unexpectedly succeeded"
[[ $fake_output == *"host deadline"* ]] || fail "hung fake Docker did not report its deadline: $fake_output"
(( ${#fake_output} < 8192 )) || fail "hung fake Docker output was not bounded"
assert_safe_cleanup "deadline path"

: >"$fake_log"
set +e
fake_output=$(run_fake overflow success 10 4096 2>&1)
fake_status=$?
set -e
((fake_status != 0)) || fail "overflowing fake Docker unexpectedly succeeded"
[[ $fake_output == *"combined container output exceeded 4096 bytes"* ]] || fail "overflow was not reported: ${fake_output:0:200}"
(( ${#fake_output} < 8192 )) || fail "overflowing fake Docker output was not bounded"
assert_safe_cleanup "output-cap path"

: >"$fake_log"
set +e
fake_output=$(run_fake success failure 5 4096 2>&1)
fake_status=$?
set -e
((fake_status != 0)) || fail "cleanup failure unexpectedly succeeded"
[[ $fake_output == *"failed to remove validated container CID $expected_cid after 2 attempts"* ]] || fail "cleanup failure was not reported: $fake_output"
[[ $fake_output == *"retained private runtime directory"* ]] || fail "failed cleanup discarded its recovery CID: $fake_output"
cleanup_count=$(grep -c "^rm cid=$expected_cid$" "$fake_log" | tr -d '[:space:]')
[[ $cleanup_count == 2 ]] || fail "cleanup failure was not retried exactly twice: $cleanup_count"
assert_safe_cleanup "cleanup-failure path"

: >"$fake_log"
fake_profile_output="$profile_parent/fake-success"
fake_output=$(run_fake_profile "$fake_profile_output" success success)
[[ $fake_output == *"profile artifacts published"* ]] || fail "profile publication was not reported: $fake_output"
for artifact in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
  [[ -f $fake_profile_output/$artifact && ! -L $fake_profile_output/$artifact ]] || fail "fake profile is missing $artifact"
done
[[ $(find "$fake_profile_output" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]') == 5 ]] || fail "fake profile output contains an unexpected artifact"
for artifact in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
  grep -q "^exec cid=$expected_cid artifact=$artifact$" "$fake_log" || fail "profile artifact $artifact was not copied by validated CID"
done
grep -q "^stop cid=$expected_cid$" "$fake_log" || fail "profile container was not stopped by validated CID"
assert_safe_cleanup "profile-success path"

for copy_mode in failure empty overflow hang; do
  : >"$fake_log"
  failed_profile_output="$profile_parent/fake-$copy_mode"
  set +e
  fake_output=$(run_fake_profile "$failed_profile_output" "$copy_mode" success 2>&1)
  fake_status=$?
  set -e
  ((fake_status != 0)) || fail "profile copy mode $copy_mode unexpectedly succeeded"
  [[ ! -e $failed_profile_output && ! -L $failed_profile_output ]] || fail "failed profile mode $copy_mode published output"
  assert_safe_cleanup "profile-$copy_mode path"
done

: >"$fake_log"
cleanup_failed_profile="$profile_parent/fake-cleanup-failure"
set +e
fake_output=$(run_fake_profile "$cleanup_failed_profile" success failure 2>&1)
fake_status=$?
set -e
((fake_status != 0)) || fail "profile cleanup failure unexpectedly succeeded"
[[ ! -e $cleanup_failed_profile && ! -L $cleanup_failed_profile ]] || fail "profile artifacts were published before validated-CID cleanup"
cleanup_count=$(grep -c "^rm cid=$expected_cid$" "$fake_log" | tr -d '[:space:]')
[[ $cleanup_count == 2 ]] || fail "profile cleanup failure was not attempted exactly twice: $cleanup_count"
assert_safe_cleanup "profile-cleanup-failure path"

: >"$fake_log"
stop_failed_profile="$profile_parent/fake-stop-hang"
set +e
fake_output=$(run_fake_profile "$stop_failed_profile" success success hang 1 2>&1)
fake_status=$?
set -e
((fake_status != 0)) || fail "hanging profile stop unexpectedly succeeded"
[[ ! -e $stop_failed_profile && ! -L $stop_failed_profile ]] || fail "hanging profile stop published artifacts"
assert_safe_cleanup "profile-stop-hang path"

mkdir "$profile_parent/existing"
if run_fake_profile "$profile_parent/existing" success success >/dev/null 2>&1; then
  fail "existing profile output was accepted"
fi

unsafe_profile_parent="$temporary_directory/unsafe-profile-parent"
mkdir "$unsafe_profile_parent"
chmod 0777 "$unsafe_profile_parent"
if ASSESSMENT_DOCKER_IMAGE="$construction_image" bash "$runner" --print-command \
  "$fixture_directory" profile Balanced 1s "$unsafe_profile_parent/profiles" >/dev/null 2>&1; then
  fail "group/world-writable profile parent was accepted"
fi

runtime_unavailable() {
  local reason=$1
  if [[ $require_runtime == 1 ]]; then
    fail "$reason"
  fi
  echo "isolation command tests passed; Docker runtime test skipped ($reason)"
  exit 0
}

if [[ -z $configured_image ]]; then
  runtime_unavailable "ASSESSMENT_DOCKER_IMAGE digest not configured"
fi

if ! command -v docker >/dev/null 2>&1; then
  runtime_unavailable "docker CLI unavailable"
fi
if ! docker info >/dev/null 2>&1; then
  runtime_unavailable "docker daemon unavailable"
fi

if ! docker image inspect "$configured_image" >/dev/null 2>&1; then
  runtime_unavailable "digest-pinned image not present: $configured_image"
fi

if ! test_output=$(ASSESSMENT_DOCKER_IMAGE="$configured_image" bash "$runner" "$fixture_directory" test 2>&1); then
  fail "Docker functional runtime canary failed: $test_output"
fi
[[ ! -e $fixture_directory/host-write ]] || fail "container wrote to the host workspace"
if ! benchmark_output=$(ASSESSMENT_DOCKER_IMAGE="$configured_image" bash "$runner" "$fixture_directory" benchmark 1x 1 2>&1); then
  fail "Docker 1x benchmark runtime canary failed: $benchmark_output"
fi
[[ $benchmark_output == *"BenchmarkAnalyze/IsolationCanary"* ]] || fail "Docker benchmark canary produced no benchmark row: $benchmark_output"
runtime_profile_output="$profile_parent/runtime"
if ! profile_output=$(ASSESSMENT_DOCKER_IMAGE="$configured_image" bash "$runner" \
  "$fixture_directory" profile Balanced 1s "$runtime_profile_output" 2>&1); then
  fail "Docker profile runtime canary failed: $profile_output"
fi
for artifact in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
  [[ -s $runtime_profile_output/$artifact && ! -L $runtime_profile_output/$artifact ]] || fail "Docker profile runtime canary is missing $artifact"
done
echo "isolation command and Docker runtime tests passed"
