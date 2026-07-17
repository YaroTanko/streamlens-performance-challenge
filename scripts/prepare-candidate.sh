#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <baseline-directory> <candidate-directory> <output-directory>" >&2
  exit 2
}

die() {
  echo "prepare-candidate: $*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
fi

baseline_input=$1
candidate_input=$2
output_input=$3

for input in "$baseline_input" "$candidate_input" "$output_input"; do
  [[ $input != *$'\n'* && $input != *$'\r'* ]] || die "paths containing newlines are not supported"
done

physical_directory() {
  local input=$1
  local label=$2

  [[ -d $input ]] || die "$label is not a directory: $input"
  [[ ! -L $input ]] || die "$label must not be a symbolic link: $input"
  (cd -- "$input" && pwd -P)
}

require_regular_file() {
  local root=$1
  local relative=$2
  local label=$3
  local current=$root
  local component
  local index
  local -a components

  IFS='/' read -r -a components <<<"$relative"
  for ((index = 0; index < ${#components[@]} - 1; index++)); do
    component=${components[$index]}
    current="$current/$component"
    [[ -d $current ]] || die "$label has a missing or non-directory path component: $relative"
    [[ ! -L $current ]] || die "$label has a symbolic-link path component: $relative"
  done

  current="$root/$relative"
  [[ ! -L $current ]] || die "$label must be a regular file, not a symbolic link: $relative"
  [[ -f $current ]] || die "$label must be a regular file: $relative"
  [[ -r $current ]] || die "$label is not readable: $relative"
}

paths_overlap() {
  local left=$1
  local right=$2

  [[ $left == "$right" || $left == "$right/"* || $right == "$left/"* ]]
}

directory_metadata() {
  local directory=$1
  local mode
  local owner

  if mode=$(stat -f '%Lp' "$directory" 2>/dev/null) && owner=$(stat -f '%u' "$directory" 2>/dev/null); then
    :
  else
    mode=$(stat -c '%a' "$directory")
    owner=$(stat -c '%u' "$directory")
  fi
  [[ $mode =~ ^[0-7]{3,4}$ && $owner =~ ^[0-9]+$ ]] || die "cannot verify output parent ownership and permissions"
  printf '%s %s\n' "$mode" "$owner"
}

baseline_directory=$(physical_directory "$baseline_input" "baseline directory")
candidate_directory=$(physical_directory "$candidate_input" "candidate directory")

output_parent_input=$(dirname -- "$output_input")
output_name=$(basename -- "$output_input")
[[ $output_name != "." && $output_name != ".." && $output_name != "/" && -n $output_name ]] || die "invalid output directory: $output_input"
[[ -d $output_parent_input ]] || die "output parent is not a directory: $output_parent_input"
[[ ! -L $output_parent_input ]] || die "output parent must not be a symbolic link: $output_parent_input"
output_parent=$(cd -- "$output_parent_input" && pwd -P)
[[ $output_parent != *$'\n'* && $output_parent != *$'\r'* ]] || die "canonical output parent contains a newline"
read -r output_parent_mode output_parent_owner < <(directory_metadata "$output_parent")
[[ $output_parent_owner == "$(id -u)" ]] || die "output parent must be owned by the current user"
if ((8#$output_parent_mode & 0022)); then
  die "output parent must not be group- or world-writable"
fi
output_directory="$output_parent/$output_name"
[[ ! -L $output_directory ]] || die "output directory must not be a symbolic link: $output_input"
if [[ -e $output_directory ]]; then
  die "output directory must not already exist: $output_input"
fi

if paths_overlap "$output_directory" "$baseline_directory"; then
  die "output directory overlaps the baseline directory"
fi
if paths_overlap "$output_directory" "$candidate_directory"; then
  die "output directory overlaps the candidate directory"
fi

allowed_files=(
  "internal/analyzer/engine.go"
  "OPTIMIZATION.md"
)

for relative in "${allowed_files[@]}"; do
  require_regular_file "$baseline_directory" "$relative" "baseline file"
  require_regular_file "$candidate_directory" "$relative" "candidate file"
done

staging_directory=$(mktemp -d "$output_parent/.${output_name}.prepare.XXXXXX")
cleanup() {
  if [[ -n ${staging_directory:-} && -e $staging_directory ]]; then
    rm -rf -- "$staging_directory"
  fi
}
trap cleanup EXIT HUP INT TERM

# The baseline checkout owns every trusted file. Candidate files other than the
# two explicit overlays are never traversed or copied.
cp -a "$baseline_directory/." "$staging_directory/"
rm -rf -- "$staging_directory/.git"

for relative in "${allowed_files[@]}"; do
  require_regular_file "$staging_directory" "$relative" "prepared baseline file"
  install -m 0644 "$candidate_directory/$relative" "$staging_directory/$relative"
done

# The private parent prevents another user from creating the destination during
# publication. GNU mv -T adds a no-move-into-directory guarantee; BSD mv lacks
# it, so the portable fallback repeats the absence check immediately before mv.
if mv -T -- "$staging_directory" "$output_directory" 2>/dev/null; then
  :
else
  [[ -e $staging_directory ]] || die "staging directory disappeared during publication"
  [[ ! -e $output_directory && ! -L $output_directory ]] || die "output directory appeared during publication"
  mv -- "$staging_directory" "$output_directory"
fi
staging_directory=
trap - EXIT HUP INT TERM

printf '%s\n' "$output_directory"
