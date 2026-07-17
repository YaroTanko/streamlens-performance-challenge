#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_directory=$(cd -- "$script_directory/.." && pwd -P)
dispatch_script="$project_directory/.github/scripts/dispatch-private-evaluator.sh"
workflow="$project_directory/.github/workflows/assessment.yml"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-dispatch-test.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

fail() {
  echo "dispatch-private-evaluator-test: $*" >&2
  exit 1
}

fake_bin="$temporary_directory/bin"
argument_log="$temporary_directory/arguments"
mkdir -m 0700 "$fake_bin"

apply_fake_gh() {
  local replacement=$1
  sed "s|@@ARGUMENT_LOG@@|$replacement|g" \
    "$project_directory/scripts/testdata/fake-dispatch-gh.sh" >"$fake_bin/gh"
  chmod 0755 "$fake_bin/gh"
}

apply_fake_gh "$argument_log"

candidate_repository='candidate-user/streamlens-performance-challenge'
candidate_base='0123456789abcdef0123456789abcdef01234567'
candidate_sha='89abcdef0123456789abcdef0123456789abcdef'
candidate_pr_number='42'
source_run_url='https://github.com/YaroTanko/streamlens-performance-challenge/actions/runs/123456789'
test_token='dispatch-test-token-that-must-not-be-an-argument'
uppercase_base=$(printf '%s' "$candidate_base" | tr '[:lower:]' '[:upper:]')

output=$(PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" "$candidate_sha" \
    "$candidate_pr_number" "$source_run_url")

[[ $output == *"Private evaluator dispatched"* ]] || fail 'success was not reported'
grep -Fxq -- '--method' "$argument_log" || fail 'POST method flag is missing'
grep -Fxq -- 'POST' "$argument_log" || fail 'POST method is missing'
grep -Fxq -- 'repos/YaroTanko/streamlens-performance-evaluator/actions/workflows/evaluate.yml/dispatches' "$argument_log" || \
  fail 'private workflow endpoint is incorrect'
grep -Fxq -- "inputs[candidate_repository]=$candidate_repository" "$argument_log" || \
  fail 'candidate repository input is missing'
grep -Fxq -- "inputs[candidate_base_sha]=$candidate_base" "$argument_log" || \
  fail 'candidate base input is missing'
grep -Fxq -- "inputs[candidate_sha]=$candidate_sha" "$argument_log" || \
  fail 'candidate SHA input is missing'
grep -Fxq -- "inputs[candidate_pr_number]=$candidate_pr_number" "$argument_log" || \
  fail 'candidate PR number input is missing'
grep -Fxq -- "inputs[source_run_url]=$source_run_url" "$argument_log" || \
  fail 'source run URL input is missing'
if grep -Fq -- "$test_token" "$argument_log"; then
  fail 'dispatch token leaked into command arguments'
fi

for invalid in \
  'candidate;repo' \
  'candidate/repo/extra' \
  '../candidate'; do
  if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
    bash "$dispatch_script" "$invalid" "$candidate_base" "$candidate_sha" \
      "$candidate_pr_number" "$source_run_url" >/dev/null 2>&1; then
    fail "invalid candidate repository was accepted: $invalid"
  fi
done

if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
  bash "$dispatch_script" "$candidate_repository" "$uppercase_base" "$candidate_sha" \
    "$candidate_pr_number" "$source_run_url" >/dev/null 2>&1; then
  fail 'uppercase candidate base SHA was accepted'
fi
if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" short \
    "$candidate_pr_number" "$source_run_url" >/dev/null 2>&1; then
  fail 'short candidate SHA was accepted'
fi
if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" "$candidate_sha" \
    zero "$source_run_url" >/dev/null 2>&1; then
  fail 'invalid candidate PR number was accepted'
fi
if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" "$candidate_sha" \
    "$candidate_pr_number" 'https://example.com/actions/runs/1' >/dev/null 2>&1; then
  fail 'foreign source run URL was accepted'
fi
if env -u GH_TOKEN PATH="$fake_bin:$PATH" \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" "$candidate_sha" \
    "$candidate_pr_number" "$source_run_url" >/dev/null 2>&1; then
  fail 'missing dispatch token was accepted'
fi
if PATH="$fake_bin:$PATH" GH_TOKEN="$test_token" FAKE_GH_EXIT=17 \
  bash "$dispatch_script" "$candidate_repository" "$candidate_base" "$candidate_sha" \
    "$candidate_pr_number" "$source_run_url" >/dev/null 2>&1; then
  fail 'GitHub API failure was ignored'
fi

# shellcheck disable=SC2016 # These are literal workflow shell expressions.
for required_workflow_text in \
  'pull_request_target:' \
  'github.event.pull_request.draft == false' \
  'github.workflow_sha' \
  'ref: ${{ env.WORKFLOW_SHA }}' \
  'PRIVATE_EVALUATOR_DISPATCH_TOKEN' \
  'steps.candidate_preflight.outcome' \
  'steps.private_evaluator.outcome' \
  'steps.revisions.outputs.candidate_base_sha' \
  'candidate_base_sha=%s' \
  'workflow-source/.github/scripts/derive-candidate-base.sh' \
  'workflow-source/.github/scripts/dispatch-private-evaluator.sh' \
  '"$CANDIDATE_REPOSITORY"' \
  '"$CANDIDATE_BASE_SHA"' \
  '"$CANDIDATE_PR_NUMBER"' \
  '"$SOURCE_RUN_URL"' \
  '"$CANDIDATE_SHA"'; do
  grep -Fq -- "$required_workflow_text" "$workflow" || \
    fail "assessment workflow is missing $required_workflow_text"
done

echo 'private evaluator dispatch tests passed'
