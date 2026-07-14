#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-commit> <candidate-commit>" >&2
  exit 2
fi

base_commit=$1
candidate_commit=$2

changed_paths=()
while IFS= read -r path; do
  changed_paths+=("$path")
done < <(git diff --name-only --diff-filter=ACDMRTUXB "$base_commit" "$candidate_commit")

if [[ ${#changed_paths[@]} -eq 0 ]]; then
  echo "No candidate changes found." >&2
  exit 1
fi

protected_changes=()
engine_changed=false
optimization_changed=false
for path in "${changed_paths[@]}"; do
  case "$path" in
    internal/analyzer/engine.go)
      engine_changed=true
      ;;
    OPTIMIZATION.md)
      optimization_changed=true
      ;;
    *)
      protected_changes+=("$path")
      ;;
  esac
done

if [[ ${#protected_changes[@]} -gt 0 ]]; then
  echo "Protected assessment files changed:" >&2
  printf '  - %s\n' "${protected_changes[@]}" >&2
  echo "Only internal/analyzer/engine.go and OPTIMIZATION.md may be changed." >&2
  exit 1
fi

missing_deliverables=()
if [[ $engine_changed != true ]]; then
  missing_deliverables+=("internal/analyzer/engine.go")
fi
if [[ $optimization_changed != true ]]; then
  missing_deliverables+=("OPTIMIZATION.md")
fi
if [[ ${#missing_deliverables[@]} -gt 0 ]]; then
  echo "Required candidate deliverables were not changed:" >&2
  printf '  - %s\n' "${missing_deliverables[@]}" >&2
  exit 1
fi

if [[ ! -f OPTIMIZATION.md ]]; then
  echo "OPTIMIZATION.md must exist in the candidate revision." >&2
  exit 1
fi
if grep -Fq -- 'Replace this template' OPTIMIZATION.md; then
  echo "OPTIMIZATION.md still contains the candidate template instruction." >&2
  exit 1
fi

bullet_count=$(awk '
  /^[[:space:]]*[-*+][[:space:]]+[^[:space:]]/ { count++ }
  END { print count + 0 }
' OPTIMIZATION.md)
if [[ $bullet_count -lt 5 || $bullet_count -gt 10 ]]; then
  echo "OPTIMIZATION.md must contain 5-10 non-empty Markdown bullet lines; found $bullet_count." >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*[-*+][[:space:]]+Profile evidence:[[:space:]]*[^[:space:]]' OPTIMIZATION.md; then
  echo "OPTIMIZATION.md must include a non-empty bullet in the form '- Profile evidence: <measured observation>'." >&2
  exit 1
fi

echo "Protected-file check passed."
