# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

go_has_local_replace() {
  local file="$1"
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    {
      line = $0
      sub(/[[:space:]]*\/\/.*/, "", line)
      if (line !~ /=>/) next
      replacement = substr(line, index(line, "=>") + 2)
      replacement = trim(replacement)
      gsub(/^["\047]|["\047]$/, "", replacement)
      if (replacement ~ /^(\/|~\/|[.][.]?\/)/ ||
          replacement ~ /^[A-Za-z]:[\\\/]/ || replacement ~ /^\\\\/) found=1
    }
    END { exit !found }
  ' "$file"
}

validate_go_mod_document() {
  local file="$1"
  awk '
    /^[[:space:]]*(\/\/.*)?$/ { next }
    /^[[:space:]]*module[[:space:]]+[^[:space:]]+[[:space:]]*$/ {
      if (module_seen) exit 2
      module_seen=1
      next
    }
    /^[[:space:]]*go[[:space:]]+[0-9]+[.][0-9]+([.][0-9]+)?[[:space:]]*$/ {
      if (go_seen) exit 2
      go_seen=1
      next
    }
    { exit 2 }
    END { if (!module_seen) exit 2 }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "go.mod is malformed or outside the dependency-free portable subset; pass --task NAME=COMMAND for a manual contract"
}

require_tracked_go_source() {
  local directory="$1" relative tracked_sources source
  if [ "$directory" = "$PROJECT_ROOT" ]; then relative=""; else relative="${directory#"$PROJECT_ROOT"/}"; fi
  if [ -n "$relative" ]; then
    tracked_sources="$(git -C "$PROJECT_ROOT" ls-files -- "$relative" | awk -v prefix="$relative/" '
      function selected(path, count, part, parts, base) {
        path=substr(path, length(prefix) + 1)
        count=split(path, parts, "/")
        for (part=1; part<count; part++) {
          if (parts[part] == "vendor" || parts[part] == "testdata" || parts[part] ~ /^[._]/) return 0
        }
        base=parts[count]
        return base ~ /[.]go$/ && base !~ /^[._]/
      }
      selected($0)
    ')"
  else
    tracked_sources="$(git -C "$PROJECT_ROOT" ls-files | awk '
      function selected(path, count, part, parts, base) {
        count=split(path, parts, "/")
        for (part=1; part<count; part++) {
          if (parts[part] == "vendor" || parts[part] == "testdata" || parts[part] ~ /^[._]/) return 0
        }
        base=parts[count]
        return base ~ /[.]go$/ && base !~ /^[._]/
      }
      selected($0)
    ')"
  fi
  [ -n "$tracked_sources" ] \
    || contract_refusal "Go target '${directory#"$PROJECT_ROOT"/}' has no tracked Go source"
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    [ -f "$PROJECT_ROOT/$source" ] && [ ! -L "$PROJECT_ROOT/$source" ] \
      || contract_refusal "Go source '$source' is not a regular tracked file"
  done <<<"$tracked_sources"
}

verify_go_packages() {
  local directory="$1" output detail source relative selected=false verified=true
  command -v go >/dev/null 2>&1 \
    || contract_refusal "Go automatic adoption requires the Go tool to verify selected packages offline; install Go or pass --task NAME=COMMAND"
  if output="$(cd "$directory" \
    && GOENV=off GOTOOLCHAIN=local GOWORK=off GOPROXY=off GOSUMDB=off \
      go list -f '{{range .GoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .CXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .MFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .HFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .FFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SwigCXXFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .SysoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .TestGoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .XTestGoFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}{{range .EmbedFiles}}{{$.Dir}}/{{.}}{{"\n"}}{{end}}' ./... 2>&1)"; then
    while IFS= read -r source; do
      [ -n "$source" ] || continue
      selected=true
      case "$source" in "$PROJECT_ROOT"/*) ;; *)
        verified=false
        continue
        ;;
      esac
      relative="${source#"$PROJECT_ROOT"/}"
      [ -f "$source" ] && [ ! -L "$source" ] \
        && git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 \
        || verified=false
    done <<<"$output"
    [ "$selected" = true ] && [ "$verified" = true ] && return 0
  fi
  detail="$(printf '%s\n' "$output" | awk '
    NF {
      if (joined != "") joined=joined " "
      joined=joined $0
    }
    END { print substr(joined, 1, 300) }
  ')"
  contract_refusal "Go target has no package selected by ./... under offline local-toolchain resolution${detail:+: $detail}; pass --task NAME=COMMAND"
}
