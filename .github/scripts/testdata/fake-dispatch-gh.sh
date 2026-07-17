#!/usr/bin/env bash
set -euo pipefail

argument_log='@@ARGUMENT_LOG@@'
printf '%s\n' "$@" >"$argument_log"
exit "${FAKE_GH_EXIT:-0}"
