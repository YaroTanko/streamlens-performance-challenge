#!/usr/bin/env bash
set -euo pipefail

operation=${1:-}
shift || true
log=${FAKE_DOCKER_LOG:?FAKE_DOCKER_LOG is required}
mode=${FAKE_DOCKER_MODE:-success}
cleanup_mode=${FAKE_DOCKER_CLEANUP_MODE:-success}
copy_mode=${FAKE_DOCKER_COPY_MODE:-success}
stop_mode=${FAKE_DOCKER_STOP_MODE:-success}
state_directory=${FAKE_DOCKER_STATE:-}
cid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

case "$operation" in
  run)
    cid_file=
    for argument in "$@"; do
      case "$argument" in
        --cidfile=*) cid_file=${argument#--cidfile=} ;;
      esac
    done
    [[ -n $cid_file ]] || {
      echo "fake docker: missing --cidfile" >&2
      exit 90
    }
    printf 'run cidfile=%s\n' "$cid_file" >>"$log"
    printf '%s\n' "$cid" >"$cid_file"
    case "$mode" in
      success)
        echo "fake docker success canary"
        ;;
      hang)
        trap 'exit 143' TERM INT
        while :; do
          sleep 1
        done
        ;;
      overflow)
        printf -v chunk '%2048s' ''
        chunk=${chunk// /X}
        while :; do
          printf '%s' "$chunk"
        done
        ;;
      profile)
        [[ -n $state_directory && -d $state_directory ]] || {
          echo "fake docker: FAKE_DOCKER_STATE is required for profile mode" >&2
          exit 94
        }
        ready_token=
        for argument in "$@"; do
          ready_token=$argument
        done
        [[ $ready_token =~ ^[0-9a-f]{64}$ ]] || {
          echo "fake docker: invalid profile ready token" >&2
          exit 95
        }
        printf '@@STREAMLENS_PROFILE_READY %s\n' "$ready_token"
        while [[ ! -f $state_directory/stopped ]]; do
          sleep 0.05
        done
        ;;
      *)
        echo "fake docker: unknown run mode: $mode" >&2
        exit 91
        ;;
    esac
    ;;
  exec)
    [[ ${1:-} == --user=65532:65532 && ${2:-} == "$cid" && ${3:-} == /bin/cat && ${4:-} == /tmp/streamlens-profile/* && $# -eq 4 ]] || {
      printf 'unsafe-exec %s\n' "$*" >>"$log"
      exit 96
    }
    artifact=${4##*/}
    case "$artifact" in
      assessment.test | cpu.pprof | alloc.pprof | cpu-top.txt | alloc-top.txt) ;;
      *)
        printf 'unsafe-exec-artifact %s\n' "$artifact" >>"$log"
        exit 97
        ;;
    esac
    printf 'exec cid=%s artifact=%s\n' "$cid" "$artifact" >>"$log"
    case "$copy_mode" in
      success)
        printf 'fake profile artifact: %s\n' "$artifact"
        ;;
      failure)
        echo "fake docker profile copy failure" >&2
        exit 43
        ;;
      empty)
        ;;
      overflow)
        if [[ $artifact != cpu-top.txt ]]; then
          printf 'fake profile artifact: %s\n' "$artifact"
        else
          printf -v chunk '%2048s' ''
          chunk=${chunk// /P}
          while :; do
            printf '%s' "$chunk"
          done
        fi
        ;;
      hang)
        if [[ $artifact != cpu-top.txt ]]; then
          printf 'fake profile artifact: %s\n' "$artifact"
        else
          trap 'exit 143' TERM INT
          while :; do
            sleep 1
          done
        fi
        ;;
      *)
        echo "fake docker: unknown copy mode: $copy_mode" >&2
        exit 97
        ;;
    esac
    ;;
  stop)
    [[ ${1:-} == --timeout=1 && ${2:-} == "$cid" && $# -eq 2 ]] || {
      printf 'unsafe-stop %s\n' "$*" >>"$log"
      exit 98
    }
    [[ -n $state_directory && -d $state_directory ]] || exit 99
    printf 'stop cid=%s\n' "$cid" >>"$log"
    if [[ $stop_mode == hang ]]; then
      trap 'exit 143' TERM INT
      while :; do
        sleep 1
      done
    fi
    [[ $stop_mode == success ]] || exit 100
    : >"$state_directory/stopped"
    printf '%s\n' "$cid"
    ;;
  rm)
    [[ ${1:-} == -f && ${2:-} == -v && ${3:-} =~ ^[0-9a-f]{64}$ && $# -eq 3 ]] || {
      printf 'unsafe-rm %s\n' "$*" >>"$log"
      exit 92
    }
    printf 'rm cid=%s\n' "$3" >>"$log"
    if [[ $cleanup_mode == failure ]]; then
      echo "fake docker cleanup failure" >&2
      exit 42
    fi
    ;;
  *)
    echo "fake docker: unsupported operation: $operation" >&2
    exit 93
    ;;
esac
