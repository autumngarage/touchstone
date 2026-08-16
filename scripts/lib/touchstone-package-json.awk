# Extract supported npm scripts from one package.json without a project runtime.
# The parser validates the complete JSON document and inspects only the
# top-level "scripts" object. Output order is the Touchstone preference order.

function fail(message) {
  print "package.json: " message > "/dev/stderr"
  exit 2
}

function json_space(character) {
  return character == " " || character == "\t" || character == "\r" || character == "\n"
}

function skip_space() {
  while (position <= document_length && json_space(substr(document, position, 1))) position++
}

function hex_value(character) {
  if (character >= "0" && character <= "9") return character + 0
  character = tolower(character)
  if (character == "a") return 10
  if (character == "b") return 11
  if (character == "c") return 12
  if (character == "d") return 13
  if (character == "e") return 14
  if (character == "f") return 15
  return -1
}

function append_string(character) {
  parsed_string = parsed_string character
  if (!json_space(character) && character !~ /[[:cntrl:]]/) string_has_content = 1
}

function parse_hex_escape(    offset, value, digit, low_value) {
  value = 0
  for (offset = 0; offset < 4; offset++) {
    digit = hex_value(substr(document, position + offset, 1))
    if (digit < 0) fail("invalid Unicode escape")
    value = (value * 16) + digit
  }
  position += 4

  if (value >= 55296 && value <= 56319) {
    if (substr(document, position, 2) != "\\u") fail("unpaired high surrogate")
    position += 2
    low_value = 0
    for (offset = 0; offset < 4; offset++) {
      digit = hex_value(substr(document, position + offset, 1))
      if (digit < 0) fail("invalid Unicode escape")
      low_value = (low_value * 16) + digit
    }
    if (low_value < 56320 || low_value > 57343) fail("unpaired high surrogate")
    position += 4
    append_string("#")
    return
  }
  if (value >= 56320 && value <= 57343) fail("unpaired low surrogate")
  if (value <= 127) append_string(sprintf("%c", value))
  else append_string("#")
}

function parse_string(    character, escape) {
  if (substr(document, position, 1) != "\"") fail("expected string")
  position++
  parsed_string = ""
  string_has_content = 0
  while (position <= document_length) {
    character = substr(document, position, 1)
    position++
    if (character == "\"") return
    if (character == "\\") {
      if (position > document_length) fail("unfinished escape")
      escape = substr(document, position, 1)
      position++
      if (escape == "u") parse_hex_escape()
      else if (escape == "\"" || escape == "\\" || escape == "/") append_string(escape)
      else if (escape == "b") append_string("\b")
      else if (escape == "f") append_string("\f")
      else if (escape == "n") append_string("\n")
      else if (escape == "r") append_string("\r")
      else if (escape == "t") append_string("\t")
      else fail("invalid string escape")
    } else {
      if (character ~ /[[:cntrl:]]/) fail("unescaped control character")
      append_string(character)
    }
  }
  fail("unterminated string")
}

function parse_number(    character) {
  if (substr(document, position, 1) == "-") position++
  character = substr(document, position, 1)
  if (character == "0") position++
  else {
    if (character !~ /^[1-9]$/) fail("invalid number")
    while (substr(document, position, 1) ~ /^[0-9]$/) position++
  }
  if (substr(document, position, 1) == ".") {
    position++
    if (substr(document, position, 1) !~ /^[0-9]$/) fail("invalid number fraction")
    while (substr(document, position, 1) ~ /^[0-9]$/) position++
  }
  character = substr(document, position, 1)
  if (character == "e" || character == "E") {
    position++
    character = substr(document, position, 1)
    if (character == "+" || character == "-") position++
    if (substr(document, position, 1) !~ /^[0-9]$/) fail("invalid number exponent")
    while (substr(document, position, 1) ~ /^[0-9]$/) position++
  }
}

function parse_array(    character) {
  position++
  skip_space()
  if (substr(document, position, 1) == "]") {
    position++
    return
  }
  while (1) {
    parse_value()
    skip_space()
    character = substr(document, position, 1)
    if (character == "]") {
      position++
      return
    }
    if (character != ",") fail("expected array separator")
    position++
    skip_space()
  }
}

function parse_object(    character) {
  position++
  skip_space()
  if (substr(document, position, 1) == "}") {
    position++
    return
  }
  while (1) {
    parse_string()
    skip_space()
    if (substr(document, position, 1) != ":") fail("expected object colon")
    position++
    parse_value()
    skip_space()
    character = substr(document, position, 1)
    if (character == "}") {
      position++
      return
    }
    if (character != ",") fail("expected object separator")
    position++
    skip_space()
  }
}

function parse_value(    character) {
  skip_space()
  character = substr(document, position, 1)
  if (character == "\"") parse_string()
  else if (character == "{") parse_object()
  else if (character == "[") parse_array()
  else if (character == "-" || character ~ /^[0-9]$/) parse_number()
  else if (substr(document, position, 4) == "true") position += 4
  else if (substr(document, position, 5) == "false") position += 5
  else if (substr(document, position, 4) == "null") position += 4
  else fail("expected value")
}

function supported_script(name) {
  return name == "validate" || name == "verify" || name == "lint" || \
    name == "typecheck" || name == "test" || name == "build"
}

function parse_scripts_object(    character, name, has_content) {
  position++
  skip_space()
  if (substr(document, position, 1) == "}") {
    position++
    return
  }
  while (1) {
    parse_string()
    name = parsed_string
    if (supported_script(name)) {
      if (name in script_keys) fail("duplicate supported script name")
      script_keys[name] = 1
    }
    skip_space()
    if (substr(document, position, 1) != ":") fail("expected scripts colon")
    position++
    skip_space()
    if (supported_script(name) && substr(document, position, 1) == "\"") {
      parse_string()
      has_content = string_has_content
      if (has_content) scripts[name] = 1
    } else parse_value()
    skip_space()
    character = substr(document, position, 1)
    if (character == "}") {
      position++
      return
    }
    if (character != ",") fail("expected scripts separator")
    position++
    skip_space()
  }
}

function parse_root(    character, name) {
  skip_space()
  if (substr(document, position, 1) != "{") fail("top-level value is not an object")
  position++
  skip_space()
  if (substr(document, position, 1) == "}") fail("missing top-level scripts object")
  while (1) {
    parse_string()
    name = parsed_string
    skip_space()
    if (substr(document, position, 1) != ":") fail("expected top-level colon")
    position++
    skip_space()
    if (name == "scripts") {
      if (scripts_seen) fail("duplicate top-level scripts object")
      scripts_seen = 1
      if (substr(document, position, 1) != "{") fail("top-level scripts value is not an object")
      parse_scripts_object()
    } else parse_value()
    skip_space()
    character = substr(document, position, 1)
    if (character == "}") {
      position++
      break
    }
    if (character != ",") fail("expected top-level separator")
    position++
    skip_space()
  }
  if (!scripts_seen) fail("missing top-level scripts object")
  skip_space()
  if (position <= document_length) fail("trailing content")
}

{
  document = document $0 "\n"
}

END {
  document_length = length(document)
  position = 1
  parse_root()
  split("validate verify lint typecheck test build", preference, " ")
  for (preference_index = 1; preference_index <= 6; preference_index++) \
    if (scripts[preference[preference_index]]) print preference[preference_index]
}
