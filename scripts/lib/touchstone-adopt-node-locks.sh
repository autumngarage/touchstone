# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

npm_lock_valid() {
  local file="$1"
  validate_json_document "$file" || return 1
  awk '
    function hex_value(character, position) {
      position = index("0123456789abcdef", tolower(character))
      return position - 1
    }
    function decoded_unicode(hex, position, value) {
      value = 0
      for (position = 1; position <= 4; position++) {
        value = (value * 16) + hex_value(substr(hex, position, 1))
      }
      if (value < 128) return sprintf("%c", value)
      if (value < 2048) return sprintf("%c%c", 192 + int(value / 64), 128 + (value % 64))
      return sprintf("%c%c%c", 224 + int(value / 4096),
        128 + (int(value / 64) % 64), 128 + (value % 64))
    }
    function decoded_escape(character) {
      if (character == "b") return sprintf("%c", 8)
      if (character == "f") return sprintf("%c", 12)
      if (character == "n") return "\n"
      if (character == "r") return "\r"
      if (character == "t") return "\t"
      return character
    }
    function finish_string() {
      pending = token
      token = ""
      in_string = 0
    }
    function finish_root_literal(value) {
      value = root_literal
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (root_literal_key == "lockfileVersion") lock_version = value
      else if (root_literal_key == "requires") requires = value
      root_literal = ""
      root_literal_key = ""
    }
    function unsafe_root_package_key(key) {
      return key == "dependencies" || key == "devDependencies" \
        || key == "optionalDependencies" || key == "peerDependencies"
    }
    {
      line = $0 "\n"
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (in_string) {
          if (unicode_left > 0) {
            unicode_hex = unicode_hex character
            unicode_left--
            if (unicode_left == 0) {
              token = token decoded_unicode(unicode_hex)
              unicode_hex = ""
            }
          } else if (escaped) {
            if (character == "u") {
              unicode_left = 4
              unicode_hex = ""
            } else token = token decoded_escape(character)
            escaped = 0
          } else if (character == "\\") escaped = 1
          else if (character == "\"") finish_string()
          else token = token character
          continue
        }
        if (root_literal_key != "") {
          if (character == "," || (character == "}" && depth == 1)) {
            finish_root_literal()
          } else {
            root_literal = root_literal character
            continue
          }
        }
        if ((seeking_packages || seeking_root_package) && character ~ /[[:space:]]/) continue
        if ((seeking_packages || seeking_root_package) && character != "{") {
          invalid = 1
          seeking_packages = 0
          seeking_root_package = 0
        }
        if (character == "\"") {
          in_string = 1
          token = ""
          continue
        }
        if (character == ":") {
          key = pending
          pending = ""
          if (depth == 1 && key == "packages") {
            packages_seen++
            seeking_packages = 1
          } else if (depth == 1 && (key == "lockfileVersion" || key == "requires")) {
            if (key == "lockfileVersion") lock_seen++
            else requires_seen++
            root_literal_key = key
            root_literal = ""
          } else if (depth == 1 && unsafe_root_package_key(key)) {
            invalid = 1
          } else if (packages_depth > 0 && depth == packages_depth) {
            package_keys++
            if (key != "") invalid = 1
            seeking_root_package = 1
          } else if (root_package_depth > 0 && depth == root_package_depth \
            && unsafe_root_package_key(key)) invalid = 1
          continue
        }
        if (character == "{") {
          depth++
          if (seeking_packages) {
            packages_depth = depth
            seeking_packages = 0
          } else if (seeking_root_package) {
            root_package_depth = depth
            seeking_root_package = 0
          }
          pending = ""
          continue
        }
        if (character == "}") {
          if (depth == root_package_depth) root_package_depth = 0
          if (depth == packages_depth) packages_depth = 0
          depth--
          pending = ""
          continue
        }
        if (character !~ /[[:space:],]/) pending = ""
      }
    }
    END {
      if (root_literal_key != "") finish_root_literal()
      if (invalid || in_string || escaped || unicode_left > 0 || depth != 0 \
        || seeking_packages || seeking_root_package) exit 1
      exit !(lock_seen == 1 && (lock_version == "2" || lock_version == "3") \
        && requires_seen == 1 && requires == "true" \
        && packages_seen == 1 && package_keys == 1)
    }
  ' "$file" >/dev/null 2>&1
}

pnpm_lock_valid() {
  local file="$1"
  awk '
    /^[[:space:]]*($|#)/ { next }
    /^lockfileVersion:[[:space:]]*["\047]?[0-9]+([.][0-9]+)?["\047]?[[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      section = ""
      next
    }
    /^settings:[[:space:]]*$/ {
      if (settings_seen) exit 2
      settings_seen=1
      section = "settings"
      next
    }
    /^importers:[[:space:]]*$/ {
      if (importers_seen) exit 2
      importers_seen=1
      section = "importers"
      next
    }
    section == "settings" && /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*[^[:space:]][^#]*$/ { next }
    section == "importers" && /^  ["\047]?[.]["\047]?:[[:space:]]*[{][}][[:space:]]*$/ {
      if (root_importer_seen) exit 2
      root_importer_seen=1
      next
    }
    { exit 2 }
    END {
      if (!version_seen || (importers_seen && !root_importer_seen)) exit 2
    }
  ' "$file" >/dev/null 2>&1
}

yarn_lock_valid() {
  local file="$1" kind="$2"
  case "$kind" in
    classic)
      awk '
        /^[[:space:]]*$/ { next }
        /^# yarn lockfile v1$/ { if (header_seen) exit 2; header_seen=1; next }
        /^#/ { next }
        { exit 2 }
        END { if (!header_seen) exit 2 }
      ' "$file" >/dev/null 2>&1
      ;;
    berry)
      awk '
        /^[[:space:]]*$/ { next }
        /^__metadata:[[:space:]]*$/ {
          if (metadata_seen || workspace_seen) exit 2
          metadata_seen=1
          section = "metadata"
          next
        }
        /^  version:[[:space:]]*[0-9]+[[:space:]]*$/ {
          if (section != "metadata" || version_seen) exit 2
          version_seen=1
          next
        }
        /^  cacheKey:[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
          if (section != "metadata" || cache_seen) exit 2
          cache_seen=1
          next
        }
        /^"[^"[:space:]]+@workspace:[.]":[[:space:]]*$/ {
          if (!metadata_seen || workspace_seen) exit 2
          workspace_seen=1
          section = "workspace"
          next
        }
        section == "workspace" && /^  version:[[:space:]]*0[.]0[.]0-use[.]local[[:space:]]*$/ {
          if (workspace_version_seen) exit 2
          workspace_version_seen=1
          next
        }
        section == "workspace" && /^  resolution:[[:space:]]*"[^"[:space:]]+@workspace:[.]"[[:space:]]*$/ {
          if (resolution_seen) exit 2
          resolution_seen=1
          next
        }
        section == "workspace" && /^  languageName:[[:space:]]*unknown[[:space:]]*$/ {
          if (language_seen) exit 2
          language_seen=1
          next
        }
        section == "workspace" && /^  linkType:[[:space:]]*soft[[:space:]]*$/ {
          if (link_seen) exit 2
          link_seen=1
          next
        }
        { exit 2 }
        END {
          if (!metadata_seen || !version_seen || !workspace_seen \
            || !workspace_version_seen || !resolution_seen || !language_seen || !link_seen) exit 2
        }
      ' "$file" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}
