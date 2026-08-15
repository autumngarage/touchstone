# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

swift_has_dependency_source() {
  local file="$1" source="$2"
  awk -v source="$source" '
    /\.package[[:space:]]*\(/ { in_package=1 }
    in_package && source == "remote" && /(^|[^A-Za-z])(url|id)[[:space:]]*:/ { found=1 }
    in_package && source == "path" && /(^|[^A-Za-z])path[[:space:]]*:/ { found=1 }
    in_package && /\)/ { in_package=0 }
    END { exit !found }
  ' "$file"
}

validate_swift_manifest() {
  local file="$1" directory="$2" target source_root source_relative tracked_sources source
  target="$(awk '
    /^[[:space:]]*$/ { next }
    count == 0 && /^\/\/ swift-tools-version:[[:space:]]*[0-9]+[.][0-9]+([.][0-9]+)?[[:space:]]*$/ { count++; next }
    count == 1 && /^[[:space:]]*import[[:space:]]+PackageDescription[[:space:]]*$/ { count++; next }
    count == 2 && /^[[:space:]]*let[[:space:]]+package[[:space:]]*=[[:space:]]*Package[(][[:space:]]*$/ { count++; next }
    count == 3 && /^[[:space:]]*name:[[:space:]]*"[A-Za-z0-9._-]+",[[:space:]]*$/ { count++; next }
    count == 4 && /^[[:space:]]*targets:[[:space:]]*\[[[:space:]]*$/ { count++; next }
    count == 5 && /^[[:space:]]*[.]testTarget[(]name:[[:space:]]*"[A-Za-z0-9._-]+"[)][[:space:]]*$/ {
      target=$0
      sub(/^[[:space:]]*[.]testTarget[(]name:[[:space:]]*"/, "", target)
      sub(/"[)][[:space:]]*$/, "", target)
      count++
      next
    }
    count == 6 && /^[[:space:]]*\][[:space:]]*$/ { count++; next }
    count == 7 && /^[[:space:]]*[)][[:space:]]*$/ { count++; next }
    { invalid=1 }
    END {
      if (invalid || count != 8 || target == "") exit 2
      print target
    }
  ' "$file" 2>/dev/null)" \
    || contract_refusal "Package.swift is malformed or outside the portable buildable-target subset; pass --task NAME=COMMAND for a manual contract"
  source_root="$directory/Tests/$target"
  if [ "$directory" = "$PROJECT_ROOT" ]; then
    source_relative="Tests/$target"
  else
    source_relative="${directory#"$PROJECT_ROOT"/}/Tests/$target"
  fi
  tracked_sources="$(git -C "$PROJECT_ROOT" ls-files -- "$source_relative" | awk '/[.]swift$/')"
  [ -n "$tracked_sources" ] \
    || contract_refusal "Swift test target '$target' has no tracked Swift source"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    [ -f "$PROJECT_ROOT/$source" ] && [ ! -L "$PROJECT_ROOT/$source" ] \
      || contract_refusal "Swift test target '$target' source '$source' is not a regular tracked file"
  done <<<"$tracked_sources"
  [ -d "$source_root" ] && [ ! -L "$source_root" ] \
    || contract_refusal "Swift test target '$target' has no regular source directory"
}
