# shellcheck shell=bash

validate_json_document() {
  local file="$1"
  awk '
    function value_allowed() {
      if (depth == 0) return root_state == "value"
      if (kind[depth] == "object") return state[depth] == "value"
      return state[depth] == "value_or_end" || state[depth] == "value"
    }
    function value_complete() {
      if (depth == 0) root_state = "done"
      else state[depth] = "comma_or_end"
    }
    function begin_value(token) {
      if (!value_allowed()) { invalid = 1; return }
      if (depth == 0 && token != "{") { invalid = 1; return }
      if (token == "{") {
        depth++
        kind[depth] = "object"
        state[depth] = "key_or_end"
      } else if (token == "[") {
        depth++
        kind[depth] = "array"
        state[depth] = "value_or_end"
      } else value_complete()
    }
    function close_container(token, expected) {
      expected = token == "}" ? "object" : "array"
      if (depth == 0 || kind[depth] != expected) { invalid = 1; return }
      if (expected == "object") {
        if (state[depth] != "key_or_end" && state[depth] != "comma_or_end") {
          invalid = 1
          return
        }
      } else if (state[depth] != "value_or_end" && state[depth] != "comma_or_end") {
        invalid = 1
        return
      }
      delete kind[depth]
      delete state[depth]
      depth--
      value_complete()
    }
    function accept(token) {
      if (invalid) return
      if (token == "string" && depth > 0 && kind[depth] == "object" &&
          (state[depth] == "key_or_end" || state[depth] == "key")) {
        state[depth] = "colon"
      } else if (token == ":") {
        if (depth == 0 || kind[depth] != "object" || state[depth] != "colon") invalid = 1
        else state[depth] = "value"
      } else if (token == ",") {
        if (depth == 0 || state[depth] != "comma_or_end") invalid = 1
        else if (kind[depth] == "object") state[depth] = "key"
        else state[depth] = "value"
      } else if (token == "}" || token == "]") close_container(token)
      else begin_value(token)
    }
    function finish_raw() {
      if (raw_token == "true" || raw_token == "false" || raw_token == "null" ||
          raw_token ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) accept("scalar")
      else invalid = 1
      raw = 0
      raw_token = ""
    }
    function punctuation(character) {
      return character == "{" || character == "}" || character == "[" ||
        character == "]" || character == ":" || character == ","
    }
    BEGIN { root_state = "value" }
    {
      line = $0 "\n"
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (raw) {
          if (character ~ /[[:space:]]/ || punctuation(character)) {
            finish_raw()
            position--
          } else raw_token = raw_token character
          continue
        }
        if (in_string) {
          if (unicode_left > 0) {
            if (character !~ /^[0-9A-Fa-f]$/) invalid = 1
            unicode_left--
          } else if (escaped) {
            if (character == "u") unicode_left = 4
            else if (index("\"\\/bfnrt", character) == 0) invalid = 1
            escaped = 0
          } else if (character == "\\") escaped = 1
          else if (character == "\"") {
            in_string = 0
            accept("string")
          } else if (character ~ /[[:cntrl:]]/) invalid = 1
          continue
        }
        if (character ~ /[[:space:]]/) continue
        if (character == "\"") { in_string = 1; continue }
        if (punctuation(character)) { accept(character); continue }
        raw = 1
        raw_token = character
      }
    }
    END {
      if (raw) finish_raw()
      if (in_string || escaped || unicode_left > 0 || depth != 0 || root_state != "done") invalid = 1
      exit invalid ? 1 : 0
    }
  ' "$file"
}
json_object_has_key() {
  local file="$1" object="$2" wanted="$3"
  awk -v object="$object" -v wanted="$wanted" '
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
      if (capturing_value) {
        if (token ~ /[^[:space:]]/) found = 1
        capturing_value = 0
      } else pending = token
      token = ""
      in_string = 0
    }
    {
      line = $0 "\n"
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_string) {
          if (unicode_left > 0) {
            unicode_hex = unicode_hex c
            unicode_left--
            if (unicode_left == 0) {
              token = token decoded_unicode(unicode_hex)
              unicode_hex = ""
            }
          }
          else if (escaped) {
            if (c == "u") {
              unicode_left = 4
              unicode_hex = ""
            } else token = token decoded_escape(c)
            escaped = 0
          }
          else if (c == "\\") escaped = 1
          else if (c == "\"") finish_string()
          else token = token c
          continue
        }
        if (seeking_object && c ~ /[[:space:]]/) continue
        if (seeking_object && c != "{") { invalid = 1; seeking_object = 0 }
        if (seeking_value && c ~ /[[:space:]]/) continue
        if (seeking_value) {
          if (c == "\"") {
            seeking_value = 0
            in_string = 1
            capturing_value = 1
            token = ""
            continue
          }
          invalid = 1
          seeking_value = 0
        }
        if (c == "\"") { in_string = 1; token = ""; continue }
        if (c == ":") {
          if (depth == 1 && pending == object) {
            if (object_seen) invalid = 1
            object_seen = 1
            seeking_object = 1
          }
          else if (object_depth > 0 && depth == object_depth && pending == wanted) {
            wanted_seen++
            if (wanted_seen > 1) duplicate = 1
            seeking_value = 1
          }
          pending = ""
          continue
        }
        if (c == "{") {
          depth++
          if (seeking_object) { object_depth = depth; seeking_object = 0 }
          pending = ""
          continue
        }
        if (c == "}") {
          if (depth <= 0) invalid = 1
          if (depth == object_depth) object_depth = 0
          depth--
          pending = ""
          continue
        }
        if (c !~ /[[:space:]]/) pending = ""
      }
    }
    END {
      if (invalid || duplicate || in_string || escaped || unicode_left > 0 || depth != 0 || seeking_object || seeking_value) exit 2
      exit !found
    }
  ' "$file"
}
json_object_has_local_path() {
  local file="$1" object="$2" match_mode="${3:-local}"
  awk -v object="$object" -v match_mode="$match_mode" '
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
    function local_path(value, lower) {
      lower = tolower(value)
      return lower ~ /^(file|link):/ || value ~ /^(\/|~\/|[.][.]?\/)/ ||
        value ~ /^[A-Za-z]:[\\\/]/ || value ~ /^\\\\/
    }
    function finish_string() {
      if (capturing_value) {
        if (match_mode == "any" || local_path(token)) found = 1
        capturing_value = 0
      } else pending = token
      token = ""
      in_string = 0
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
        if (seeking_object && character ~ /[[:space:]]/) continue
        if (seeking_object && character != "{") { invalid = 1; seeking_object = 0 }
        if (seeking_value && character ~ /[[:space:]]/) continue
        if (seeking_value) {
          if (character == "\"") {
            seeking_value = 0
            in_string = 1
            capturing_value = 1
            token = ""
            continue
          }
          invalid = 1
          seeking_value = 0
        }
        if (character == "\"") { in_string = 1; token = ""; continue }
        if (character == ":") {
          if (depth == 1 && pending == object) {
            if (object_seen) invalid = 1
            object_seen = 1
            seeking_object = 1
          } else if (object_depth > 0 && depth == object_depth) {
            seeking_value = 1
          }
          pending = ""
          continue
        }
        if (character == "{") {
          depth++
          if (seeking_object) { object_depth = depth; seeking_object = 0 }
          pending = ""
          continue
        }
        if (character == "}") {
          if (depth <= 0) invalid = 1
          if (depth == object_depth) object_depth = 0
          depth--
          pending = ""
          continue
        }
        if (character !~ /[[:space:]]/) pending = ""
      }
    }
    END {
      if (invalid || in_string || escaped || unicode_left > 0 || depth != 0 || seeking_object || seeking_value) exit 2
      exit !found
    }
  ' "$file"
}

validate_toml_document() {
  local file="$1" label="$2"
  awk '
    function invalid_document() { invalid = 1; exit 2 }
    function hex_number(value, number, cursor, digit) {
      number = 0
      for (cursor = 1; cursor <= length(value); cursor++) {
        digit = index("0123456789abcdef", tolower(substr(value, cursor, 1))) - 1
        number = (number * 16) + digit
      }
      return number
    }
    function valid_bare_value(value) {
      return value ~ /^(true|false|[+-]?(inf|nan))$/ \
        || value ~ /^[+-]?(0|[1-9][0-9]*)$/ \
        || value ~ /^0x[0-9A-Fa-f]+$/ \
        || value ~ /^0o[0-7]+$/ \
        || value ~ /^0b[01]+$/ \
        || value ~ /^[+-]?(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?$/ \
        || value ~ /^[+-]?(0|[1-9][0-9]*)[eE][+-]?[0-9]+$/
    }
    function finish_bare() {
      if (!bare) return
      if (bare_is_value && !valid_bare_value(bare_token)) invalid_document()
      bare = 0
      bare_space = 0
      bare_token = ""
      bare_is_value = 0
    }
    function path_conflicts_with_value(path, existing) {
      for (existing in defined_path) {
        if (path == existing || index(path, existing ".") == 1 || index(existing, path ".") == 1) return 1
      }
      return 0
    }
    function record_key(scope, key_name, path, existing) {
      if (key_name !~ /^[A-Za-z0-9_.-]+$/) invalid_document()
      path = scope == "" ? key_name : scope "." key_name
      if (path_conflicts_with_value(path) || table_kind[path] != "") invalid_document()
      for (existing in table_kind) {
        if (index(existing, path ".") == 1) invalid_document()
      }
      defined_path[path] = 1
    }
    function enter_table(value, table_name, is_array, path, existing) {
      value = trim_toml(value)
      sub(/[[:space:]]*#.*/, "", value)
      value = trim_toml(value)
      is_array = substr(value, 1, 2) == "[["
      if (is_array) table_name = substr(value, 3, length(value) - 4)
      else table_name = substr(value, 2, length(value) - 2)
      table_name = trim_toml(table_name)
      if (table_name !~ /^[A-Za-z0-9_.-]+$/ || path_conflicts_with_value(table_name)) invalid_document()
      if (is_array) {
        if (table_kind[table_name] == "table") invalid_document()
        table_kind[table_name] = "array"
        table_instance[table_name]++
        current_table = table_name "#" table_instance[table_name]
      } else {
        if (table_kind[table_name] != "") invalid_document()
        for (existing in table_kind) {
          if (table_kind[existing] == "array" && (table_name == existing || index(table_name, existing ".") == 1)) invalid_document()
        }
        table_kind[table_name] = "table"
        current_table = table_name
      }
    }
    function trim_toml(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function begin_value() {
      if (depth > 0 && kind[depth] == "array") {
        if (!expect_value[depth]) invalid_document()
        expect_value[depth] = 0
      } else if (depth > 0 && kind[depth] == "inline") {
        if (inline_state[depth] != "value") invalid_document()
        inline_state[depth] = "done"
      } else if (depth == 0) {
        if (!assignment || assignment_value) invalid_document()
        assignment_value = 1
      }
    }
    function begin_scalar() {
      if (depth > 0 && kind[depth] == "inline" && inline_state[depth] == "key") {
        inline_key[depth] = 1
        scalar_value = 0
        return
      }
      if (depth == 0 && !assignment) {
        scalar_value = 0
        return
      }
      begin_value()
      scalar_value = 1
    }
    function inline_key_conflicts(id, key_name, index_value, existing) {
      for (index_value = 1; index_value <= inline_key_count[id]; index_value++) {
        existing = inline_key_name[id, index_value]
        if (key_name == existing || index(key_name, existing ".") == 1 || index(existing, key_name ".") == 1) return 1
      }
      return 0
    }
    function push(container) {
      begin_value()
      depth++
      kind[depth] = container
      if (container == "array") expect_value[depth] = 1
      else {
        inline_state[depth] = "key"
        inline_serial++
        inline_id[depth] = inline_serial
      }
    }
    function pop(container) {
      if (depth < 1 || kind[depth] != container) invalid_document()
      if (container == "inline" && inline_state[depth] != "done" \
          && !(inline_state[depth] == "key" && !inline_key[depth] && !inline_had_entry[depth])) invalid_document()
      delete kind[depth]
      delete expect_value[depth]
      delete inline_state[depth]
      delete inline_key[depth]
      delete inline_had_entry[depth]
      delete inline_id[depth]
      depth--
    }
    function valid_table_header(value) {
      return value ~ /^[[:space:]]*\[[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*\][[:space:]]*(#.*)?$/ \
        || value ~ /^[[:space:]]*\[\[[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*\]\][[:space:]]*(#.*)?$/
    }
    {
      sub(/\r$/, "")
      line = $0

      if (depth == 0 && line ~ /^[[:space:]]*\[/) {
        if (!valid_table_header(line)) invalid_document()
        enter_table(line)
        next
      }

      if (depth == 0) {
        assignment = 0
        assignment_value = 0
      }
      bare = 0
      bare_space = 0
      saw_content = depth > 0
      quote = ""
      escaped = 0
      unicode_left = 0
      unicode_hex = ""
      for (position = 1; position <= length(line); position++) {
        character = substr(line, position, 1)
        if (quote != "") {
          if (quote == "\"" && unicode_left > 0) {
            if (character !~ /^[0-9A-Fa-f]$/) invalid_document()
            unicode_hex = unicode_hex character
            unicode_left--
            if (unicode_left == 0) {
              unicode_value = hex_number(unicode_hex)
              if (unicode_value > 1114111 || (unicode_value >= 55296 && unicode_value <= 57343)) invalid_document()
              unicode_hex = ""
            }
            continue
          }
          if (quote == "\"" && escaped) {
            if (character == "u") { unicode_left = 4; unicode_hex = "" }
            else if (character == "U") { unicode_left = 8; unicode_hex = "" }
            else if (character !~ /^[btnfr"\\]$/) invalid_document()
            escaped = 0
            continue
          }
          if (quote == "\"" && character == "\\") { escaped = 1; continue }
          if (character == quote) { quote = ""; continue }
          continue
        }
        if (character == "#") break
        if (character ~ /[[:space:]]/) {
          if (bare) bare_space = 1
          continue
        }
        saw_content = 1
        if (substr(line, position, 3) == "\"\"\"" || substr(line, position, 3) == "\047\047\047") {
          invalid_document()
        }
        if (character == "\"" || character == "\047") {
          if (bare) invalid_document()
          begin_scalar()
          quote = character
          bare = 0
          bare_space = 0
          continue
        }
        if (character == "[") { if (bare) invalid_document(); push("array"); continue }
        if (character == "]") { finish_bare(); pop("array"); continue }
        if (character == "{") { if (bare) invalid_document(); push("inline"); continue }
        if (character == "}") { finish_bare(); pop("inline"); continue }
        if (character == ",") {
          finish_bare()
          if (depth > 0 && kind[depth] == "array") {
            if (expect_value[depth]) invalid_document()
            expect_value[depth] = 1
          } else if (depth > 0 && kind[depth] == "inline") {
            if (inline_state[depth] != "done") invalid_document()
            inline_state[depth] = "key"
            inline_key[depth] = 0
          }
          bare = 0
          bare_space = 0
          continue
        }
        if (character == "=") {
          key_name = bare_token
          finish_bare()
          if (depth == 0) {
            if (assignment) invalid_document()
            record_key(current_table, key_name)
            assignment = 1
          } else if (kind[depth] == "inline") {
            if (inline_state[depth] != "key" || !inline_key[depth]) invalid_document()
            if (key_name !~ /^[A-Za-z0-9_.-]+$/ || inline_key_conflicts(inline_id[depth], key_name)) invalid_document()
            inline_key_count[inline_id[depth]]++
            inline_key_name[inline_id[depth], inline_key_count[inline_id[depth]]] = key_name
            inline_state[depth] = "value"
            inline_had_entry[depth] = 1
          } else {
            invalid_document()
          }
          bare = 0
          bare_space = 0
          continue
        }
        if (!bare) {
          begin_scalar()
          bare = 1
          bare_is_value = scalar_value
          bare_token = character
        } else if (bare_space) {
          invalid_document()
        } else {
          bare_token = bare_token character
        }
      }
      if (quote != "" || escaped || unicode_left > 0) invalid_document()
      finish_bare()
      for (level = 1; level <= depth; level++) {
        if (kind[level] == "inline") invalid_document()
      }
      if (depth == 0 && saw_content) {
        if (!assignment || !assignment_value) invalid_document()
      }
    }
    END {
      if (invalid || depth != 0) exit 2
    }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "$label is malformed or uses TOML syntax the portable adoption parser cannot verify; pass --task NAME=COMMAND for a manual contract"
}
