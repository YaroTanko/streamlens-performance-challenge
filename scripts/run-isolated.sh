#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  run-isolated.sh [--print-command] <prepared-directory> test
  run-isolated.sh [--print-command] <prepared-directory> benchmark [benchtime] [gomaxprocs]
  run-isolated.sh [--print-command] <prepared-directory> profile <scenario> <profile-time> <new-output-directory>
USAGE
  exit 2
}

die() {
  echo "run-isolated: $*" >&2
  exit 2
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

print_command=false
if [[ ${1:-} == "--print-command" ]]; then
  print_command=true
  shift
fi

[[ $# -ge 2 ]] || usage
prepared_input=$1
mode=$2
shift 2

[[ $prepared_input != *$'\n'* && $prepared_input != *$'\r'* && $prepared_input != *,* ]] || die "prepared path contains an unsupported character"
[[ -d $prepared_input ]] || die "prepared directory does not exist: $prepared_input"
[[ ! -L $prepared_input ]] || die "prepared directory must not be a symbolic link"
prepared_directory=$(cd -- "$prepared_input" && pwd -P)
[[ $prepared_directory != *$'\n'* && $prepared_directory != *$'\r'* && $prepared_directory != *,* ]] || die "canonical prepared path contains an unsupported character"
[[ -f $prepared_directory/go.mod && ! -L $prepared_directory/go.mod ]] || die "prepared directory must contain a regular go.mod"

bench_time=${BENCH_TIME:-300ms}
benchmark_gomaxprocs=${BENCH_GOMAXPROCS:-1}
test_gomaxprocs=${ASSESSMENT_TEST_GOMAXPROCS:-2}
profile_mode=false
profile_scenario=
profile_time=
profile_output_directory=
profile_output_parent=
profile_output_name=
profile_ready_token=
profile_ready_line=
case "$mode" in
  test)
    [[ $# -eq 0 ]] || usage
    if ! [[ $test_gomaxprocs =~ ^[1-8]$ ]]; then
      die "ASSESSMENT_TEST_GOMAXPROCS must be an integer between 1 and 8"
    fi
    gomaxprocs=$test_gomaxprocs
    container_cpus=$test_gomaxprocs
    # shellcheck disable=SC2016 # Expanded by /bin/sh inside the container.
    container_script='set -eu
mkdir -p "$HOME" "$GOCACHE" "$GOTMPDIR" "$GOMODCACHE"
exec go test ./... -count=1 -timeout=5m'
    container_arguments=(-ceu "$container_script")
    ;;
  benchmark)
    if [[ $# -ge 1 ]]; then
      bench_time=$1
    fi
    [[ $# -le 2 ]] || usage
    [[ $benchmark_gomaxprocs == 1 ]] || die "authoritative benchmark GOMAXPROCS must be 1"
    if [[ $# -ge 2 && $2 != 1 ]]; then
      die "authoritative benchmark GOMAXPROCS must be 1"
    fi
    if ! [[ $bench_time =~ ^([1-9][0-9]*x|[0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))$ ]]; then
      die "invalid benchmark time: $bench_time"
    fi
    gomaxprocs=1
    container_cpus=1
    # shellcheck disable=SC2016 # Expanded by /bin/sh inside the container.
    container_script='set -eu
mkdir -p "$HOME" "$GOCACHE" "$GOTMPDIR" "$GOMODCACHE"
exec go test ./internal/assessment \
  -run "^$" \
  -bench "^BenchmarkAnalyze$" \
  -benchmem \
  -benchtime "$1" \
  -count 1 \
  -cpu "$2" \
  -timeout 5m'
    container_arguments=(-ceu "$container_script" -- "$bench_time" "$gomaxprocs")
    ;;
  profile)
    [[ $# -eq 3 ]] || usage
    profile_mode=true
    profile_scenario=$1
    profile_time=$2
    profile_output_input=$3
    case "$profile_scenario" in
      Balanced | HighCardinality | MostlyFiltered) ;;
      *) die "invalid profiling scenario: $profile_scenario" ;;
    esac
    if ! [[ $profile_time =~ ^([0-9]+([.][0-9]+)?)(ms|s|m)$ ]]; then
      die "invalid profiling time: $profile_time"
    fi
    profile_time_value=${BASH_REMATCH[1]}
    [[ $profile_time_value =~ [1-9] ]] || die "profiling time must be greater than zero"
    [[ $profile_output_input != *$'\n'* && $profile_output_input != *$'\r'* ]] || die "profile output path contains an unsupported character"
    profile_output_parent_input=$(dirname -- "$profile_output_input")
    profile_output_name=$(basename -- "$profile_output_input")
    [[ -n $profile_output_name && $profile_output_name != . && $profile_output_name != .. && $profile_output_name != / ]] || die "invalid profile output directory: $profile_output_input"
    [[ -d $profile_output_parent_input && ! -L $profile_output_parent_input ]] || die "profile output parent must be a non-symbolic-link directory: $profile_output_parent_input"
    profile_output_parent=$(cd -- "$profile_output_parent_input" && pwd -P)
    profile_output_directory="$profile_output_parent/$profile_output_name"
    [[ ! -e $profile_output_directory && ! -L $profile_output_directory ]] || die "profile output directory must not already exist: $profile_output_input"
    paths_overlap "$profile_output_directory" "$prepared_directory" && die "profile output directory overlaps the prepared tree"
    read -r profile_parent_owner profile_parent_mode < <(directory_owner_and_mode "$profile_output_parent")
    [[ $profile_parent_owner == "$EUID" ]] || die "profile output parent must be owned by the current user"
    profile_parent_mode_value=$((8#$profile_parent_mode))
    (( (profile_parent_mode_value & 0022) == 0 )) || die "profile output parent must not be group- or world-writable"

    gomaxprocs=1
    container_cpus=1
    if [[ $print_command == true ]]; then
      profile_ready_token='<random-ready-token>'
    else
      profile_ready_token=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')
      [[ $profile_ready_token =~ ^[0-9a-f]{64}$ ]] || die "could not generate profile readiness token"
    fi
    profile_ready_line="@@STREAMLENS_PROFILE_READY $profile_ready_token"
    # The ready marker keeps the container alive just long enough for bounded,
    # fixed-file extraction through the validated CID. Profile data stays on
    # container tmpfs; no writable host directory is mounted into candidate code.
    # shellcheck disable=SC2016 # Expanded by /bin/sh inside the container.
    container_script='set -eu
umask 077
mkdir -p "$HOME" "$GOCACHE" "$GOTMPDIR" "$GOMODCACHE"
profile_directory=/tmp/streamlens-profile
mkdir -m 700 "$profile_directory"
benchmark_pattern="^BenchmarkAnalyze$/^${1}$"
go test -o "$profile_directory/assessment.test" ./internal/assessment \
  -run "^$" \
  -bench "$benchmark_pattern" \
  -benchtime "$2" \
  -count 1 \
  -cpu 1 \
  -timeout 5m \
  -cpuprofile "$profile_directory/cpu.pprof"
go tool pprof -top -nodecount=20 \
  "$profile_directory/assessment.test" "$profile_directory/cpu.pprof" \
  >"$profile_directory/cpu-top.txt"
go test -o "$profile_directory/assessment.test" ./internal/assessment \
  -run "^$" \
  -bench "$benchmark_pattern" \
  -benchtime "$2" \
  -count 1 \
  -cpu 1 \
  -timeout 5m \
  -memprofile "$profile_directory/alloc.pprof"
go tool pprof -top -nodecount=20 -sample_index=alloc_space \
  "$profile_directory/assessment.test" "$profile_directory/alloc.pprof" \
  >"$profile_directory/alloc-top.txt"
for artifact in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
  test -f "$profile_directory/$artifact"
  test ! -L "$profile_directory/$artifact"
  test -s "$profile_directory/$artifact"
done
printf "@@STREAMLENS_PROFILE_READY %s\n" "$3"
while :; do sleep 1; done'
    container_arguments=(-ceu "$container_script" -- "$profile_scenario" "$profile_time" "$profile_ready_token")
    ;;
  *)
    die "unknown mode: $mode"
    ;;
esac

image=${ASSESSMENT_DOCKER_IMAGE:-}
[[ -n $image ]] || die "ASSESSMENT_DOCKER_IMAGE must name a digest-pinned image"
if [[ $image != *@sha256:* ]]; then
  die "ASSESSMENT_DOCKER_IMAGE must use an immutable @sha256 digest"
fi
image_name=${image%@sha256:*}
image_digest=${image##*@sha256:}
if ! [[ $image_name =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ && $image_digest =~ ^[0-9a-f]{64}$ ]]; then
  die "invalid digest-pinned Docker image reference"
fi

host_deadline_seconds=${ASSESSMENT_DOCKER_DEADLINE_SECONDS:-360}
max_output_bytes=${ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES:-8388608}
if ! [[ $host_deadline_seconds =~ ^[1-9][0-9]{0,2}$ ]] || ((host_deadline_seconds > 600)); then
  die "ASSESSMENT_DOCKER_DEADLINE_SECONDS must be an integer between 1 and 600"
fi
if ! [[ $max_output_bytes =~ ^[1-9][0-9]{3,7}$ ]] || ((max_output_bytes < 4096 || max_output_bytes > 16777216)); then
  die "ASSESSMENT_DOCKER_OUTPUT_LIMIT_BYTES must be an integer between 4096 and 16777216"
fi

# Bash documents ulimit -f in 1024-byte units outside POSIX mode on both
# macOS and Linux. The subshell explicitly disables POSIX mode before applying
# the limit. Slack leaves room for Docker's own bounded failure diagnostic.
capture_slack_bytes=65536
capture_file_limit_bytes=$((max_output_bytes + capture_slack_bytes))
capture_file_limit_blocks=$(((capture_file_limit_bytes + 1023) / 1024))
watchdog_grace_seconds=1
cleanup_deadline_seconds=5
cleanup_attempts=2
profile_control_deadline_seconds=${ASSESSMENT_DOCKER_CONTROL_DEADLINE_SECONDS:-30}
if ! [[ $profile_control_deadline_seconds =~ ^[1-9][0-9]?$ ]] || ((profile_control_deadline_seconds > 60)); then
  die "ASSESSMENT_DOCKER_CONTROL_DEADLINE_SECONDS must be an integer between 1 and 60"
fi
profile_staging_directory=
profile_published=false

if [[ $print_command == true ]]; then
  runtime_directory="<private-runtime-directory>"
else
  command -v docker >/dev/null 2>&1 || die "docker is required"
  runtime_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-isolated.XXXXXX")
  chmod 0700 "$runtime_directory"
  if [[ $profile_mode == true ]]; then
    profile_staging_directory=$(mktemp -d "$profile_output_parent/.streamlens-profile.XXXXXX")
    chmod 0700 "$profile_staging_directory"
  fi
fi
cid_file="$runtime_directory/container.cid"
capture_file="$runtime_directory/combined-output"
deadline_marker="$runtime_directory/deadline-exceeded"

docker_command=(
  docker run
  --pull=never
  --cidfile="$cid_file"
  --entrypoint=/bin/sh
  --init
  --stop-timeout=1
  --read-only
  --network=none
  --ipc=none
  --log-driver=none
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=256
  --memory=2g
  --memory-swap=2g
  --cpus="$container_cpus"
  --ulimit=nofile=1024:1024
  --ulimit=core=0:0
  --user=65532:65532
  "--tmpfs=/tmp:rw,nosuid,nodev,exec,size=1g,mode=1777"
  --mount "type=bind,source=$prepared_directory,target=/workspace,readonly"
  --workdir=/workspace
  --env=HOME=/tmp/home
  --env=TMPDIR=/tmp
  --env=GOCACHE=/tmp/go-build
  --env=GOTMPDIR=/tmp/go-tmp
  --env=GOMODCACHE=/tmp/go-mod
  --env=GOPROXY=off
  --env=GOSUMDB=off
  --env=GOTOOLCHAIN=local
  --env=GOVCS=*:off
  --env=GOWORK=off
  --env=GOENV=off
  --env=CGO_ENABLED=0
  --env="GOMAXPROCS=$gomaxprocs"
  --env="GOFLAGS=-mod=readonly -buildvcs=false"
  --env=HTTP_PROXY=
  --env=HTTPS_PROXY=
  --env=ALL_PROXY=
  --env=NO_PROXY=
  --env=http_proxy=
  --env=https_proxy=
  --env=all_proxy=
  --env=no_proxy=
  --env=FTP_PROXY=
  --env=ftp_proxy=
  "$image"
  "${container_arguments[@]}"
)

if [[ $print_command == true ]]; then
  printf '(set +o posix; ulimit -S -f %q; ' "$capture_file_limit_blocks"
  printf '%q ' "${docker_command[@]}"
  printf ') >%q 2>&1 &\n' "$capture_file"
  printf '# watchdog: sleep %q; TERM; sleep %q; KILL docker-client-pid\n' "$host_deadline_seconds" "$watchdog_grace_seconds"
  printf '# bounded output: emit at most %q bytes; file hard limit %q bytes (+rounding)\n' "$max_output_bytes" "$capture_file_limit_bytes"
  if [[ $profile_mode == true ]]; then
    printf '# profile extraction: wait for exact random ready marker; docker exec validated-CID /bin/cat each fixed artifact into bounded private files; validate exact artifacts; docker stop validated-CID\n'
  fi
  printf '# cleanup: read validated 64-hex CID from %q; docker rm -f -v CID; attempts=%q; deadline=%qs\n' "$cid_file" "$cleanup_attempts" "$cleanup_deadline_seconds"
  exit 0
fi

docker_launched=false
container_removed=false
cleanup_exhausted=false
docker_pid=
watchdog_pid=

stop_background_process() {
  local process_id=${1:-}
  if [[ -n $process_id ]] && kill -0 "$process_id" 2>/dev/null; then
    kill -TERM "$process_id" 2>/dev/null || true
    sleep 0.1
    kill -KILL "$process_id" 2>/dev/null || true
  fi
  if [[ -n $process_id ]]; then
    wait "$process_id" 2>/dev/null || true
  fi
}

watch_process_deadline() (
  local process_id=$1
  local deadline_seconds=$2
  local marker_file=${3:-}
  local timer_pid=

  # shellcheck disable=SC2329 # Invoked by watchdog traps.
  stop_timer() {
    if [[ -n $timer_pid ]] && kill -0 "$timer_pid" 2>/dev/null; then
      kill -TERM "$timer_pid" 2>/dev/null || true
    fi
    if [[ -n $timer_pid ]]; then
      wait "$timer_pid" 2>/dev/null || true
    fi
  }
  trap 'stop_timer; exit 0' EXIT HUP INT TERM

  sleep "$deadline_seconds" &
  timer_pid=$!
  wait "$timer_pid"
  timer_pid=

  if kill -0 "$process_id" 2>/dev/null; then
    if [[ -n $marker_file ]]; then
      printf 'deadline exceeded\n' >"$marker_file"
    fi
    kill -TERM "$process_id" 2>/dev/null || true
    sleep "$watchdog_grace_seconds"
    kill -KILL "$process_id" 2>/dev/null || true
  fi
)

# shellcheck disable=SC2329 # Reached through the EXIT-trap cleanup chain.
read_validated_cid() {
  local cid_size
  [[ -f $cid_file && ! -L $cid_file ]] || return 1
  cid_size=$(wc -c <"$cid_file" | tr -d '[:space:]')
  [[ $cid_size == 64 || $cid_size == 65 ]] || return 1
  cid=$(<"$cid_file")
  [[ $cid =~ ^[0-9a-f]{64}$ ]]
}

run_profile_stop_command() {
  local control_output=$1
  local control_pid
  local control_watchdog_pid
  local control_status

  (
    trap - EXIT HUP INT TERM
    exec docker stop --timeout=1 "$cid"
  ) >"$control_output" 2>&1 &
  control_pid=$!
  watch_process_deadline "$control_pid" "$profile_control_deadline_seconds" "" </dev/null >/dev/null 2>&1 &
  control_watchdog_pid=$!

  set +e
  wait "$control_pid"
  control_status=$?
  set -e
  stop_background_process "$control_watchdog_pid"
  if [[ $control_status -ne 0 ]]; then
    echo "run-isolated: bounded docker stop failed (exit $control_status)" >&2
    if [[ -f $control_output && ! -L $control_output ]]; then
      head -c 4096 "$control_output" >&2
      printf '\n' >&2
    fi
  fi
  return "$control_status"
}

copy_profile_artifact() {
  local name=$1
  local limit=$2
  local destination="$profile_staging_directory/$name"
  local error_output="$runtime_directory/profile-copy-$name.stderr"
  local copy_pid
  local copy_watchdog_pid
  local copy_status
  local file_limit_blocks=$(((limit + capture_slack_bytes + 1023) / 1024))

  (
    trap - EXIT HUP INT TERM
    set +o posix
    ulimit -S -f "$file_limit_blocks"
    exec docker exec --user=65532:65532 "$cid" /bin/cat "/tmp/streamlens-profile/$name"
  ) >"$destination" 2>"$error_output" &
  copy_pid=$!
  watch_process_deadline "$copy_pid" "$profile_control_deadline_seconds" "" </dev/null >/dev/null 2>&1 &
  copy_watchdog_pid=$!

  set +e
  wait "$copy_pid"
  copy_status=$?
  set -e
  stop_background_process "$copy_watchdog_pid"
  if [[ $copy_status -ne 0 ]]; then
    echo "run-isolated: bounded profile copy failed for $name (exit $copy_status)" >&2
    if [[ -f $error_output && ! -L $error_output ]]; then
      head -c 4096 "$error_output" >&2
      printf '\n' >&2
    fi
    rm -f -- "$destination"
    return "$copy_status"
  fi
}

validate_profile_artifacts() {
  local entry
  local entry_count=0
  local name
  local size
  local limit

  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    name=${entry##*/}
    case "$name" in
      assessment.test)
        limit=134217728
        ;;
      cpu.pprof | alloc.pprof)
        limit=67108864
        ;;
      cpu-top.txt | alloc-top.txt)
        limit=1048576
        ;;
      *)
        echo "run-isolated: unexpected profile artifact: $name" >&2
        return 1
        ;;
    esac
    if [[ ! -f $entry || -L $entry ]]; then
      echo "run-isolated: profile artifact must be a regular non-symbolic-link file: $name" >&2
      return 1
    fi
    size=$(wc -c <"$entry" | tr -d '[:space:]')
    if ! [[ $size =~ ^[0-9]+$ ]] || ((size == 0 || size > limit)); then
      echo "run-isolated: profile artifact has an invalid size: $name ($size bytes)" >&2
      return 1
    fi
  done < <(find "$profile_staging_directory" -mindepth 1 -maxdepth 1 -print0)

  [[ $entry_count -eq 5 ]] || {
    echo "run-isolated: expected exactly 5 profile artifacts, found $entry_count" >&2
    return 1
  }
  for name in assessment.test cpu.pprof alloc.pprof cpu-top.txt alloc-top.txt; do
    [[ -f $profile_staging_directory/$name && ! -L $profile_staging_directory/$name ]] || {
      echo "run-isolated: missing profile artifact: $name" >&2
      return 1
    }
  done
}

# shellcheck disable=SC2329 # Reached through the EXIT-trap cleanup chain.
run_cleanup_attempt() {
  local cleanup_output=$1
  local cleanup_pid
  local cleanup_watchdog_pid
  local cleanup_status
  local cleanup_limit_blocks=64

  (
    trap - EXIT HUP INT TERM
    set +o posix
    ulimit -S -f "$cleanup_limit_blocks"
    exec docker rm -f -v "$cid"
  ) >"$cleanup_output" 2>&1 &
  cleanup_pid=$!
  watch_process_deadline "$cleanup_pid" "$cleanup_deadline_seconds" "" </dev/null >/dev/null 2>&1 &
  cleanup_watchdog_pid=$!

  set +e
  wait "$cleanup_pid"
  cleanup_status=$?
  set -e
  stop_background_process "$cleanup_watchdog_pid"
  return "$cleanup_status"
}

# shellcheck disable=SC2329 # Reached through the EXIT-trap cleanup chain.
remove_container() {
  local attempt
  local cleanup_output

  [[ $docker_launched == true ]] || return 0
  [[ $container_removed == false ]] || return 0
  [[ $cleanup_exhausted == false ]] || return 1
  if ! read_validated_cid; then
    echo "run-isolated: no validated container CID is available for cleanup" >&2
    return 1
  fi

  for ((attempt = 1; attempt <= cleanup_attempts; attempt++)); do
    cleanup_output="$runtime_directory/cleanup-$attempt"
    if run_cleanup_attempt "$cleanup_output"; then
      container_removed=true
      return 0
    fi
  done

  echo "run-isolated: failed to remove validated container CID $cid after $cleanup_attempts attempts" >&2
  if [[ -f $cleanup_output ]]; then
    head -c 4096 "$cleanup_output" >&2
    printf '\n' >&2
  fi
  cleanup_exhausted=true
  return 1
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish() {
  local status=$?
  local cleanup_succeeded=true
  trap - EXIT HUP INT TERM
  stop_background_process "$watchdog_pid"
  stop_background_process "$docker_pid"
  if ! remove_container; then
    status=2
    cleanup_succeeded=false
  fi
  if [[ $cleanup_succeeded == true ]]; then
    rm -rf -- "$runtime_directory"
  else
    if read_validated_cid; then
      echo "run-isolated: retained private runtime directory $runtime_directory for unresolved CID $cid" >&2
    else
      echo "run-isolated: retained private runtime directory $runtime_directory because container cleanup could not be verified" >&2
    fi
  fi
  if [[ $profile_published == false && -n $profile_staging_directory && -d $profile_staging_directory && ! -L $profile_staging_directory ]]; then
    rm -rf -- "$profile_staging_directory"
  fi
  exit "$status"
}

# shellcheck disable=SC2329 # Invoked by signal traps.
handle_signal() {
  local status=$1
  stop_background_process "$docker_pid"
  exit "$status"
}
trap finish EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Raw stdout/stderr is intentional: the trusted host-side sample runner captures
# and frames it. No host results directory is visible inside the container.
(
  trap - EXIT HUP INT TERM
  set +o posix
  ulimit -S -f "$capture_file_limit_blocks"
  exec "${docker_command[@]}"
) >"$capture_file" 2>&1 &
docker_pid=$!
docker_launched=true

watch_process_deadline "$docker_pid" "$host_deadline_seconds" "$deadline_marker" </dev/null >/dev/null 2>&1 &
watchdog_pid=$!

profile_ready=false
profile_extracted=false
if [[ $profile_mode == true ]]; then
  while kill -0 "$docker_pid" 2>/dev/null; do
    if grep -Fqx -- "$profile_ready_line" "$capture_file" 2>/dev/null; then
      profile_ready=true
      break
    fi
    sleep 0.05
  done

  if [[ $profile_ready == true ]]; then
    if ! read_validated_cid; then
      echo "run-isolated: profile became ready without a validated container CID" >&2
      exit 2
    fi
    copy_profile_artifact assessment.test 134217728 || exit 2
    copy_profile_artifact cpu.pprof 67108864 || exit 2
    copy_profile_artifact alloc.pprof 67108864 || exit 2
    copy_profile_artifact cpu-top.txt 1048576 || exit 2
    copy_profile_artifact alloc-top.txt 1048576 || exit 2
    if ! validate_profile_artifacts; then
      exit 2
    fi
    if ! run_profile_stop_command "$runtime_directory/profile-stop-output"; then
      exit 2
    fi
    profile_extracted=true
  fi
fi

set +e
wait "$docker_pid"
docker_status=$?
set -e
docker_pid=
stop_background_process "$watchdog_pid"
watchdog_pid=

captured_size=$(wc -c <"$capture_file" | tr -d '[:space:]')
if ((captured_size > max_output_bytes)); then
  head -c "$max_output_bytes" "$capture_file"
  echo "run-isolated: combined container output exceeded $max_output_bytes bytes" >&2
  exit 2
fi
if [[ $profile_mode == true ]]; then
  captured_line=
  while IFS= read -r captured_line || [[ -n $captured_line ]]; do
    [[ $captured_line == "$profile_ready_line" ]] || printf '%s\n' "$captured_line"
  done <"$capture_file"
else
  cat "$capture_file"
fi
if [[ -f $deadline_marker ]]; then
  echo "run-isolated: container exceeded the ${host_deadline_seconds}s host deadline" >&2
  exit 124
fi
if [[ $profile_mode == true ]]; then
  if [[ $profile_extracted != true ]]; then
    echo "run-isolated: profile container exited before trusted artifact extraction completed" >&2
    exit 2
  fi
  if ! remove_container; then
    exit 2
  fi
  [[ ! -e $profile_output_directory && ! -L $profile_output_directory ]] || {
    echo "run-isolated: profile output directory appeared during extraction: $profile_output_directory" >&2
    exit 2
  }
  if mv -T -- "$profile_staging_directory" "$profile_output_directory" 2>/dev/null; then
    :
  else
    [[ -e $profile_staging_directory ]] || {
      echo "run-isolated: profile staging directory disappeared during publication" >&2
      exit 2
    }
    [[ ! -e $profile_output_directory && ! -L $profile_output_directory ]] || {
      echo "run-isolated: profile output directory appeared during publication: $profile_output_directory" >&2
      exit 2
    }
    if ! mv -- "$profile_staging_directory" "$profile_output_directory"; then
      echo "run-isolated: could not publish profile artifacts atomically" >&2
      exit 2
    fi
  fi
  profile_published=true
  profile_staging_directory=
  docker_status=0
  echo "run-isolated: profile artifacts published to $profile_output_directory"
fi
exit "$docker_status"
