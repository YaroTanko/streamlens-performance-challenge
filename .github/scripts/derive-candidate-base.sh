#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <candidate-checkout> <upstream-checkout> <base-tip-sha> <candidate-sha>" >&2
  exit 2
}

die() {
  echo "derive-candidate-base: $*" >&2
  exit 2
}

[[ $# -eq 4 ]] || usage

candidate_checkout=$1
upstream_checkout=$2
base_tip_sha=$3
candidate_sha=$4

[[ -d $candidate_checkout/.git && ! -L $candidate_checkout/.git ]] || \
  die 'candidate checkout is not a regular Git repository'
[[ -d $upstream_checkout/.git && ! -L $upstream_checkout/.git ]] || \
  die 'upstream checkout is not a regular Git repository'
[[ $base_tip_sha =~ ^[0-9a-f]{40}$ ]] || \
  die 'base tip must be a full lowercase 40-character Git SHA'
[[ $candidate_sha =~ ^[0-9a-f]{40}$ ]] || \
  die 'candidate revision must be a full lowercase 40-character Git SHA'

git -C "$candidate_checkout" \
  -c core.fsmonitor=false \
  -c core.hooksPath=/dev/null \
  -c protocol.file.allow=always \
  fetch --quiet --no-tags "$upstream_checkout" \
  "+${base_tip_sha}:refs/assessment/pull-request-base" >/dev/null

mapfile -t candidate_bases < <(git -C "$candidate_checkout" \
  -c core.fsmonitor=false \
  -c core.hooksPath=/dev/null \
  merge-base --all "$base_tip_sha" "$candidate_sha")
if [[ ${#candidate_bases[@]} -ne 1 || ! ${candidate_bases[0]} =~ ^[0-9a-f]{40}$ ]]; then
  die "expected one exact candidate merge base, found ${#candidate_bases[@]}"
fi
candidate_base_sha=${candidate_bases[0]}

git -C "$upstream_checkout" \
  -c core.fsmonitor=false \
  -c core.hooksPath=/dev/null \
  merge-base --is-ancestor "$candidate_base_sha" "$base_tip_sha" || \
  die 'derived base is not an ancestor of the pull request base tip'
git -C "$candidate_checkout" \
  -c core.fsmonitor=false \
  -c core.hooksPath=/dev/null \
  merge-base --is-ancestor "$candidate_base_sha" "$candidate_sha" || \
  die 'derived base is not an ancestor of the candidate revision'

printf '%s\n' "$candidate_base_sha"
