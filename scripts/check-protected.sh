#!/usr/bin/env bash
set -euo pipefail

readonly allowed_engine='internal/analyzer/engine.go'
readonly allowed_notes='OPTIMIZATION.md'
readonly protected_types='internal/analyzer/types.go'

usage() {
  echo "usage: $0 <base-commit> <candidate-commit>" >&2
  exit 2
}

fail() {
  echo "$*" >&2
  exit 1
}

trusted_git() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_COMMON_DIR \
    -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CONFIG \
    -u GIT_CONFIG_COUNT \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_NOSYSTEM \
    -u GIT_EXEC_PATH \
    -u GIT_EXTERNAL_DIFF \
    -u GIT_DIFF_OPTS \
    -u GIT_PAGER \
    -u GIT_ASKPASS \
    -u GIT_SSH \
    -u GIT_SSH_COMMAND \
    -u GIT_CEILING_DIRECTORIES \
    -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
    -u GIT_TRACE \
    -u GIT_TRACE2 \
    -u GIT_TRACE2_EVENT \
    -u GIT_TRACE2_PERF \
    -u GIT_TRACE_PACKET \
    -u GIT_TRACE_PERFORMANCE \
    -u GIT_TRACE_SETUP \
    -u GIT_TRACE_SHALLOW \
    -u GIT_TRACE_PACK_ACCESS \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

display_path() {
  local path=$1
  path=${path//\\/\\\\}
  path=${path//$'\n'/\\n}
  path=${path//$'\r'/\\r}
  path=${path//$'\t'/\\t}
  printf '%s' "$path"
}

validate_commit() {
  local label=$1
  local commit=$2

  if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "$label must be a full 40-character lowercase commit SHA." >&2
    exit 2
  fi
  if [[ $(trusted_git cat-file -t "$commit" 2>/dev/null || true) != commit ]]; then
    echo "$label does not name a commit available in this repository: $commit" >&2
    exit 2
  fi
}

[[ $# -eq 2 ]] || usage

base_commit=$1
candidate_commit=$2
validate_commit 'base-commit' "$base_commit"
validate_commit 'candidate-commit' "$candidate_commit"

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trusted_root=$(cd -- "$script_directory/.." && pwd -P)
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/streamlens-protected.XXXXXX")
trap 'rm -rf "$work_directory"' EXIT
raw_diff="$work_directory/diff.raw"
go_cache="$work_directory/go-cache"
go_tmp="$work_directory/go-tmp"
mkdir -p "$go_cache" "$go_tmp"

if ! trusted_git diff-tree \
  -r \
  --no-commit-id \
  --raw \
  -z \
  --no-abbrev \
  --find-renames \
  --find-copies-harder \
  "$base_commit" "$candidate_commit" > "$raw_diff"; then
  fail 'Unable to inspect candidate tree changes.'
fi

change_count=0
engine_changed=false
notes_changed=false

while IFS= read -r -d '' header; do
  if [[ ! $header =~ ^:([0-7]{6})[[:space:]]+([0-7]{6})[[:space:]]+([0-9a-f]+)[[:space:]]+([0-9a-f]+)[[:space:]]+([A-Z][0-9]*)$ ]]; then
    fail 'Malformed raw Git diff record; refusing to validate candidate scope.'
  fi

  old_mode=${BASH_REMATCH[1]}
  new_mode=${BASH_REMATCH[2]}
  status=${BASH_REMATCH[5]}
  status_kind=${status:0:1}

  if ! IFS= read -r -d '' first_path; then
    fail 'Malformed raw Git diff path; refusing to validate candidate scope.'
  fi

  change_count=$((change_count + 1))

  if [[ $status_kind == R || $status_kind == C ]]; then
    if ! IFS= read -r -d '' second_path; then
      fail 'Malformed raw Git rename/copy path; refusing to validate candidate scope.'
    fi
    if [[ $status_kind == R ]]; then
      fail "Rename changes are not allowed: $(display_path "$first_path") -> $(display_path "$second_path")."
    fi
    fail "Copy changes are not allowed: $(display_path "$first_path") -> $(display_path "$second_path")."
  fi

  case "$first_path" in
    "$allowed_engine")
      if [[ $engine_changed == true ]]; then
        fail "Duplicate change record for $allowed_engine."
      fi
      engine_changed=true
      ;;
    "$allowed_notes")
      if [[ $notes_changed == true ]]; then
        fail "Duplicate change record for $allowed_notes."
      fi
      notes_changed=true
      ;;
    *)
      fail "Protected assessment path changed: $(display_path "$first_path"). Only $allowed_engine and $allowed_notes may be changed."
      ;;
  esac

  if [[ $new_mode == 120000 ]]; then
    fail "Symlink deliverables are not allowed: $(display_path "$first_path")."
  fi
  if [[ $new_mode == 160000 ]]; then
    fail "Submodule/gitlink deliverables are not allowed: $(display_path "$first_path")."
  fi
  if [[ $new_mode == 100755 ]]; then
    fail "Executable deliverables are not allowed: $(display_path "$first_path")."
  fi
  if [[ $status_kind != M ]]; then
    fail "Only in-place modifications are allowed for candidate deliverables: $(display_path "$first_path") has Git status $status."
  fi
  if [[ $old_mode != 100644 || $new_mode != 100644 ]]; then
    fail "Candidate deliverable must remain a non-executable regular file: $(display_path "$first_path") changed mode $old_mode -> $new_mode."
  fi
done < "$raw_diff"

if [[ $change_count -eq 0 ]]; then
  fail 'No candidate changes found.'
fi

missing_deliverables=()
if [[ $engine_changed != true ]]; then
  missing_deliverables+=("$allowed_engine")
fi
if [[ $notes_changed != true ]]; then
  missing_deliverables+=("$allowed_notes")
fi
if [[ ${#missing_deliverables[@]} -gt 0 ]]; then
  echo 'Required candidate deliverables were not changed:' >&2
  printf '  - %s\n' "${missing_deliverables[@]}" >&2
  exit 1
fi

engine_blob="$work_directory/engine.go"
types_blob="$work_directory/types.go"
notes_blob="$work_directory/OPTIMIZATION.md"
if ! trusted_git cat-file blob "$candidate_commit:$allowed_engine" > "$engine_blob"; then
  fail "$allowed_engine must exist as a blob in the candidate revision."
fi
if ! trusted_git cat-file blob "$candidate_commit:$protected_types" > "$types_blob"; then
  fail "$protected_types must exist as a blob in the candidate revision."
fi
if ! trusted_git cat-file blob "$candidate_commit:$allowed_notes" > "$notes_blob"; then
  fail "$allowed_notes must exist as a blob in the candidate revision."
fi

if ! (
  cd "$trusted_root"
  GOENV=off \
    GOCACHE="$go_cache" \
    GOPROXY=off \
    GOSUMDB=off \
    GOTOOLCHAIN=local \
    GOTMPDIR="$go_tmp" \
    GOWORK=off \
    GOFLAGS='-mod=readonly -buildvcs=false' \
    go run ./cmd/sourceaudit \
    -engine "$engine_blob" \
    -types "$types_blob" \
    -engine-name "$allowed_engine" \
    -types-name "$protected_types"
); then
  fail "Candidate source audit failed for $allowed_engine."
fi

if grep -Fq -- 'Replace this template' "$notes_blob"; then
  fail "$allowed_notes still contains the candidate template instruction."
fi

bullet_count=$(awk '
  /^[[:space:]]*[-*+][[:space:]]+[^[:space:]]/ { count++ }
  END { print count + 0 }
' "$notes_blob")
if [[ $bullet_count -lt 5 || $bullet_count -gt 10 ]]; then
  fail "$allowed_notes must contain 5-10 non-empty Markdown bullet lines; found $bullet_count."
fi

if ! grep -Eq '^[[:space:]]*[-*+][[:space:]]+Profile evidence:[[:space:]]*[^[:space:]]' "$notes_blob"; then
  fail "$allowed_notes must include a non-empty bullet in the form '- Profile evidence: <measured observation>'."
fi

echo 'Protected-file check passed.'
