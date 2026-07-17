#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly guard="$script_directory/check-protected.sh"
readonly fixtures="$script_directory/testdata/check-protected"
readonly allowed_engine='internal/analyzer/engine.go'
readonly allowed_notes='OPTIMIZATION.md'

test_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-protected-test.XXXXXX")
trap 'rm -rf "$test_directory"' EXIT

tests_run=0

new_repository() {
  local name=$1
  repository="$test_directory/$name"
  mkdir -p "$repository/internal/analyzer"
  git -C "$repository" init -q
  git -C "$repository" config user.name 'Scope Guard Test'
  git -C "$repository" config user.email 'scope-guard@example.invalid'
  git -C "$repository" config core.filemode true
  cp "$fixtures/base_engine.go" "$repository/$allowed_engine"
  cp "$fixtures/types.go" "$repository/internal/analyzer/types.go"
  cp "$fixtures/base_optimization.md" "$repository/$allowed_notes"
  git -C "$repository" add -- "$allowed_engine" internal/analyzer/types.go "$allowed_notes"
  git -C "$repository" commit -qm 'baseline'
  base_commit=$(git -C "$repository" rev-parse HEAD)
}

commit_valid_candidate() {
  local engine_fixture=${1:-legitimate_engine.go}
  local notes_fixture=${2:-valid_optimization.md}
  cp "$fixtures/$engine_fixture" "$repository/$allowed_engine"
  cp "$fixtures/$notes_fixture" "$repository/$allowed_notes"
  git -C "$repository" add -- "$allowed_engine" "$allowed_notes"
  git -C "$repository" commit -qm 'candidate'
  candidate_commit=$(git -C "$repository" rev-parse HEAD)
}

commit_current_index() {
  git -C "$repository" commit -qm 'candidate'
  candidate_commit=$(git -C "$repository" rev-parse HEAD)
}

run_guard() {
  set +e
  guard_output=$(cd "$repository" && bash "$guard" "$base_commit" "$candidate_commit" 2>&1)
  guard_status=$?
  set -e
}

expect_pass() {
  local name=$1
  tests_run=$((tests_run + 1))
  run_guard
  if [[ $guard_status -ne 0 ]]; then
    echo "not ok $tests_run - $name" >&2
    echo "$guard_output" >&2
    exit 1
  fi
  if [[ $guard_output != *'Protected-file check passed.'* ]]; then
    echo "not ok $tests_run - $name (success message missing)" >&2
    echo "$guard_output" >&2
    exit 1
  fi
  echo "ok $tests_run - $name"
}

expect_reject() {
  local name=$1
  local expected=$2
  tests_run=$((tests_run + 1))
  run_guard
  if [[ $guard_status -eq 0 ]]; then
    echo "not ok $tests_run - $name (unexpected pass)" >&2
    exit 1
  fi
  if [[ $guard_output != *"$expected"* ]]; then
    echo "not ok $tests_run - $name (missing expected diagnostic: $expected)" >&2
    echo "$guard_output" >&2
    exit 1
  fi
  echo "ok $tests_run - $name"
}

new_repository pass_legitimate
commit_valid_candidate
expect_pass 'representative legitimate optimization'

fsmonitor_sentinel="$test_directory/fsmonitor-executed"
fsmonitor_hook="$test_directory/hostile-fsmonitor.sh"
cat >"$fsmonitor_hook" <<EOF
#!/usr/bin/env bash
printf executed >"$fsmonitor_sentinel"
exit 1
EOF
chmod 0755 "$fsmonitor_hook"
git -C "$repository" config core.fsmonitor "$fsmonitor_hook"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0="$fsmonitor_hook"
expect_pass 'ignores repository and environment fsmonitor commands'
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
[[ ! -e $fsmonitor_sentinel ]] || {
  echo "not ok $tests_run - hostile fsmonitor executed on the host" >&2
  exit 1
}

new_repository reads_candidate_blobs
commit_valid_candidate
cp "$fixtures/os_engine.go" "$repository/$allowed_engine"
cp "$fixtures/template_optimization.md" "$repository/$allowed_notes"
expect_pass 'reads committed candidate blobs instead of dirty worktree files'

new_repository commented_selector
commit_valid_candidate commented_selector_engine.go
expect_pass 'commented selector and benchmark marker remain allowed'

new_repository shadowed_output
commit_valid_candidate shadowed_output_engine.go
expect_pass 'local shadowed fmt and print calls remain allowed'

new_repository no_changes
git -C "$repository" commit --allow-empty -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)
expect_reject 'empty candidate tree diff' 'No candidate changes found.'

new_repository missing_engine
cp "$fixtures/valid_optimization.md" "$repository/$allowed_notes"
git -C "$repository" add -- "$allowed_notes"
commit_current_index
expect_reject 'missing engine deliverable' 'internal/analyzer/engine.go'

new_repository missing_notes
cp "$fixtures/legitimate_engine.go" "$repository/$allowed_engine"
git -C "$repository" add -- "$allowed_engine"
commit_current_index
expect_reject 'missing optimization notes' 'OPTIMIZATION.md'

new_repository protected_path
commit_valid_candidate
printf '%s\n' 'protected change' > "$repository/README.md"
git -C "$repository" add -- README.md
git -C "$repository" commit --amend -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)
expect_reject 'ordinary protected path' 'Protected assessment path changed: README.md.'

new_repository newline_path
commit_valid_candidate
newline_path=$'protected\nfixture.txt'
printf '%s\n' 'protected change' > "$repository/$newline_path"
git -C "$repository" add -- "$newline_path"
git -C "$repository" commit --amend -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)
expect_reject 'NUL-safe path containing newline' 'Protected assessment path changed: protected\nfixture.txt.'

new_repository rename
git -C "$repository" mv -- "$allowed_engine" internal/analyzer/renamed.go
cp "$fixtures/valid_optimization.md" "$repository/$allowed_notes"
git -C "$repository" add -- "$allowed_notes"
commit_current_index
expect_reject 'rename status' 'Rename changes are not allowed: internal/analyzer/engine.go -> internal/analyzer/renamed.go.'

new_repository copy
cp "$repository/$allowed_engine" "$repository/internal/analyzer/copied.go"
commit_valid_candidate
git -C "$repository" add -- internal/analyzer/copied.go
git -C "$repository" commit --amend -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)
expect_reject 'copy status' 'Copy changes are not allowed: internal/analyzer/engine.go -> internal/analyzer/copied.go.'

new_repository deleted_deliverable
git -C "$repository" rm -q -- "$allowed_engine"
cp "$fixtures/valid_optimization.md" "$repository/$allowed_notes"
git -C "$repository" add -- "$allowed_notes"
commit_current_index
expect_reject 'deleted deliverable' 'Only in-place modifications are allowed for candidate deliverables: internal/analyzer/engine.go has Git status D.'

new_repository executable
commit_valid_candidate
chmod +x "$repository/$allowed_engine"
git -C "$repository" add -- "$allowed_engine"
git -C "$repository" commit --amend -qm 'candidate'
candidate_commit=$(git -C "$repository" rev-parse HEAD)
expect_reject 'executable mode' 'Executable deliverables are not allowed: internal/analyzer/engine.go.'

new_repository symlink
git -C "$repository" rm -q -- "$allowed_engine"
mkdir -p "$repository/internal/analyzer"
ln -s ../../OPTIMIZATION.md "$repository/$allowed_engine"
cp "$fixtures/valid_optimization.md" "$repository/$allowed_notes"
git -C "$repository" add -- "$allowed_engine" "$allowed_notes"
commit_current_index
expect_reject 'symlink mode' 'Symlink deliverables are not allowed: internal/analyzer/engine.go.'

new_repository gitlink
cp "$fixtures/valid_optimization.md" "$repository/$allowed_notes"
git -C "$repository" add -- "$allowed_notes"
git -C "$repository" update-index --add --cacheinfo "160000,$base_commit,$allowed_engine"
commit_current_index
expect_reject 'submodule/gitlink mode' 'Submodule/gitlink deliverables are not allowed: internal/analyzer/engine.go.'

new_repository stdout_source
commit_valid_candidate stdout_engine.go
expect_reject 'direct stdout manipulation' 'rejected fmt.Println'

new_repository os_source
commit_valid_candidate os_engine.go
expect_reject 'process and filesystem package access' 'rejected import "os"'

new_repository benchmark_source
commit_valid_candidate benchmark_engine.go
expect_reject 'benchmark detection literal' 'rejected benchmark marker "BenchmarkAnalyze"'

new_repository goexit_source
commit_valid_candidate goexit_engine.go
expect_reject 'runtime process termination' 'rejected runtime.Goexit'

new_repository unsafe_source
commit_valid_candidate unsafe_engine.go
expect_reject 'unsafe package access' 'rejected import "unsafe"'

new_repository escaped_unsafe_source
commit_valid_candidate escaped_unsafe_engine.go
expect_reject 'escaped unsafe import path' 'rejected import "unsafe"'

new_repository commented_import_unsafe_source
commit_valid_candidate commented_import_unsafe_engine.go
expect_reject 'comment-separated unsafe import' 'rejected import "unsafe"'

new_repository one_line_import_source
commit_valid_candidate one_line_import_engine.go
expect_reject 'semicolon one-line unsafe import' 'rejected import "unsafe"'

new_repository flag_source
commit_valid_candidate flag_engine.go
expect_reject 'flag process inspection' 'rejected import "flag"'

new_repository slog_source
commit_valid_candidate slog_engine.go
expect_reject 'structured diagnostic output' 'rejected import "log/slog"'

new_repository os_file_write_source
commit_valid_candidate os_file_write_engine.go
expect_reject 'os.File write method' 'rejected import "os"'

new_repository os_file_close_source
commit_valid_candidate os_file_close_engine.go
expect_reject 'os.File close method' 'rejected import "os"'

new_repository promoted_os_file_write_source
commit_valid_candidate promoted_os_file_write_engine.go
expect_reject 'promoted os.File write method' 'rejected import "os"'

new_repository os_interface_writer_source
commit_valid_candidate os_interface_writer_engine.go
expect_reject 'os.File concealed behind io.Writer' 'rejected import "os"'

new_repository runtime_gomaxprocs_source
commit_valid_candidate runtime_gomaxprocs_engine.go
expect_reject 'runtime GOMAXPROCS mutation' 'rejected runtime.GOMAXPROCS'

new_repository runtime_gc_source
commit_valid_candidate runtime_gc_engine.go
expect_reject 'runtime GC manipulation' 'rejected runtime.GC'

new_repository directive_source
commit_valid_candidate directive_engine.go
expect_reject 'unsafe compiler directive' 'rejected go:linkname'

new_repository template_notes
commit_valid_candidate legitimate_engine.go template_optimization.md
expect_reject 'unchanged documentation template prompt' 'still contains the candidate template instruction.'

new_repository too_few_bullets
commit_valid_candidate legitimate_engine.go too_few_bullets.md
expect_reject 'too few optimization bullets' 'must contain 5-10 non-empty Markdown bullet lines; found 4.'

new_repository missing_profile
commit_valid_candidate legitimate_engine.go missing_profile.md
expect_reject 'missing profile evidence bullet' 'must include a non-empty bullet'

echo "1..$tests_run"
