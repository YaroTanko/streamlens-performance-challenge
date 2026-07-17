#!/usr/bin/env bash
set -euo pipefail

readonly evaluator_repository='YaroTanko/streamlens-performance-evaluator'
readonly evaluator_workflow='evaluate.yml'
readonly evaluator_ref='main'

usage() {
  echo "usage: $0 <candidate-repository> <candidate-base-sha> <candidate-sha> <candidate-pr-number> <source-run-url>" >&2
  exit 2
}

die() {
  echo "private-evaluator-dispatch: $*" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage

candidate_repository=$1
candidate_base_sha=$2
candidate_sha=$3
candidate_pr_number=$4
source_run_url=$5

[[ $candidate_repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  die 'candidate repository must use owner/repository form'
candidate_owner=${candidate_repository%%/*}
candidate_name=${candidate_repository#*/}
[[ $candidate_owner != . && $candidate_owner != .. && \
   $candidate_name != . && $candidate_name != .. ]] || \
  die 'candidate repository contains an invalid path component'
[[ $candidate_base_sha =~ ^[0-9a-f]{40}$ ]] || \
  die 'candidate base must be a full lowercase 40-character Git SHA'
[[ $candidate_sha =~ ^[0-9a-f]{40}$ ]] || \
  die 'candidate revision must be a full lowercase 40-character Git SHA'
[[ $candidate_pr_number =~ ^[1-9][0-9]*$ ]] || \
  die 'candidate pull request number must be a positive integer'
[[ $source_run_url =~ ^https://github\.com/YaroTanko/streamlens-performance-challenge/actions/runs/[0-9]+$ ]] || \
  die 'source run URL is not an exact public assessment run URL'
[[ -n ${GH_TOKEN:-} ]] || \
  die 'PRIVATE_EVALUATOR_DISPATCH_TOKEN is unavailable through GH_TOKEN'
command -v gh >/dev/null 2>&1 || die 'GitHub CLI is required on the runner'

gh api \
  --method POST \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "repos/$evaluator_repository/actions/workflows/$evaluator_workflow/dispatches" \
  --raw-field "ref=$evaluator_ref" \
  --raw-field "inputs[candidate_repository]=$candidate_repository" \
  --raw-field "inputs[candidate_base_sha]=$candidate_base_sha" \
  --raw-field "inputs[candidate_sha]=$candidate_sha" \
  --raw-field "inputs[candidate_pr_number]=$candidate_pr_number" \
  --raw-field "inputs[source_run_url]=$source_run_url"

printf 'Private evaluator dispatched: %s PR #%s @ %s (base %s)\n' \
  "$candidate_repository" "$candidate_pr_number" "$candidate_sha" "$candidate_base_sha"
printf 'Runs: https://github.com/%s/actions/workflows/%s\n' \
  "$evaluator_repository" "$evaluator_workflow"
