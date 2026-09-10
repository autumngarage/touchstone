#!/usr/bin/env bash
#
# scripts/check-hosted-runners.sh -- refuse GitHub-hosted macOS and Windows
# runners in a repository's workflows.
#
# Usage:
#   bash scripts/check-hosted-runners.sh [PROJECT_DIR]
#
# Reads every .github/workflows/*.yml and *.yaml file in PROJECT_DIR (default:
# the current directory) and refuses two shapes:
#
#   1. A GitHub-hosted macOS or Windows image named on any non-comment line,
#      in any case: macos-<n>, macos-latest, windows-<n>, windows-latest, and
#      the larger-runner spellings built from them (macos-15-xlarge,
#      windows-latest-8-cores). Read as text on purpose, so a matrix entry,
#      an expression's fallback, or an env value that later reaches runs-on
#      is caught wherever it is written.
#   2. A job whose runs-on can take its label from a setting (vars.NAME or
#      vars['NAME']) without also requiring the self-hosted label (AUT-1588).
#      Read from the parsed workflow, so every form GitHub accepts -- a quoted
#      key, an indentationless sequence, a flow list, a group-and-labels
#      mapping, a YAML alias -- is the same to the check. A list with a
#      self-hosted item requires every label together and passes. Otherwise
#      every setting reference is judged on its own, because a selector can
#      wrap one branch and leave another bare: a reference is safe only as
#      the value of format('[..."self-hosted"...]', vars.NAME), or as a
#      condition -- compared, negated, followed by &&, or passed to contains,
#      startsWith, or endsWith. Labels compare case-insensitively, as GitHub
#      compares them.
#
# Why: one macOS minute consumes about ten included Actions minutes, and the
# September 2026 overage came from exactly this. The shared validate workflow
# runs this on every pull request, so the rule holds in every consumer rather
# than in per-repository tests (AUT-1592). A line scanner for rule 2 was
# replaced after review kept finding spellings it did not model
# (touchstone#1189).
#
# Needs bash and ruby (its Psych YAML parser), both present on GitHub's
# ubuntu-latest image and on macOS.
#
# Exit 0 when clean, 1 on any finding (a workflow that does not parse is one),
# 2 on a usage or read error.

set -euo pipefail

usage() {
  printf 'Usage: bash scripts/check-hosted-runners.sh [PROJECT_DIR]\n' >&2
  exit 2
}

case "${1:-}" in -h | --help) usage ;; esac
[ "$#" -le 1 ] || usage
project="${1:-.}"
[ -d "$project" ] || {
  printf 'ERROR: project directory %s does not exist\n' "$project" >&2
  exit 2
}
command -v ruby >/dev/null 2>&1 || {
  printf 'ERROR: ruby is required; its Psych parser reads the workflows\n' >&2
  exit 2
}

exec ruby -rpsych - "$project" <<'RUBY'
project = ARGV.fetch(0)
dir = File.join(project, ".github", "workflows")

# GitHub reads workflows only from the top level of .github/workflows.
unless File.exist?(dir)
  puts "hosted-runner check: no workflow files in #{dir}; nothing to check."
  exit 0
end
begin
  names = Dir.children(dir)
rescue SystemCallError => e
  warn "ERROR: cannot read #{dir}: #{e.message}"
  exit 2
end
files = names.select { |n| n.end_with?(".yml", ".yaml") }
             .map { |n| File.join(dir, n) }
             .select { |p| File.file?(p) }
             .sort
if files.empty?
  puts "hosted-runner check: no workflow files in #{dir}; nothing to check."
  exit 0
end

HOSTED = /(?:\A|[^a-z0-9_.-])((?:macos|windows)-(?:latest|[0-9])[a-z0-9._-]*)/i
SETTING_REF = /\bvars\s*(?:\.\s*[A-Za-z_][A-Za-z0-9_-]*|\[\s*'[^']*'\s*\])/

# Can a setting reference in TEXT become a runner label? Each reference is
# judged on its own: one wrapped branch never excuses a bare one beside it.
def exposes_setting?(text)
  text.to_enum(:scan, SETTING_REF).any? do
    match = Regexp.last_match
    before = text[0...match.begin(0)]
    after = text[match.end(0)..-1]
    wrapped = before =~ /format\(\s*'[^']*self-hosted[^']*'\s*,\s*\z/i
    condition = after =~ /\A\s*(?:==|!=|<=|>=|<|>|&&)/ ||
                before =~ /(?:==|!=|<=|>=|<|>)\s*\z/ ||
                before =~ /!\s*\z/ ||
                before =~ /\b(?:contains|startsWith|endsWith)\(\s*(?:'[^']*'\s*,\s*)?\z/i
    !(wrapped || condition)
  end
end

# A runs-on list, or a mapping's labels list, with a self-hosted item requires
# every label together, so no setting in it can select a hosted runner.
def lists_self_hosted?(node, anchors)
  node = resolve(node, anchors)
  if node.is_a?(Psych::Nodes::Mapping)
    labels = entry(node, "labels")
    return labels ? lists_self_hosted?(labels[1], anchors) : false
  end
  return false unless node.is_a?(Psych::Nodes::Sequence)
  node.children.any? do |child|
    child = resolve(child, anchors)
    child.is_a?(Psych::Nodes::Scalar) && child.value.strip.casecmp?("self-hosted")
  end
end

# The key and value nodes for KEY in a mapping node, or nil.
def entry(mapping, key)
  mapping.children.each_slice(2) do |k, v|
    return [k, v] if k.is_a?(Psych::Nodes::Scalar) && k.value == key
  end
  nil
end

def resolve(node, anchors)
  node.is_a?(Psych::Nodes::Alias) ? anchors[node.anchor] : node
end

# Every scalar under NODE, following aliases once each.
def scalars(node, anchors, seen = {})
  case node
  when Psych::Nodes::Scalar then [node.value]
  when Psych::Nodes::Alias
    return [] if seen[node.anchor]
    scalars(anchors[node.anchor], anchors, seen.merge(node.anchor => true))
  when Psych::Nodes::Sequence, Psych::Nodes::Mapping
    node.children.flat_map { |child| scalars(child, anchors, seen) }
  else
    []
  end
end

findings = []
files.each do |path|
  begin
    text = File.read(path)
  rescue SystemCallError => e
    warn "ERROR: cannot read #{path}: #{e.message}"
    exit 2
  end

  text.each_line.with_index(1) do |line, number|
    next if line =~ /\A\s*#/
    match = line.sub(/\s#.*/m, "").match(HOSTED)
    next unless match
    findings << "#{path}:#{number}: names the GitHub-hosted image '#{match[1].downcase}'; macOS and Windows work runs only on a self-hosted runner that a setting names"
  end

  begin
    document = Psych.parse(text)
  rescue Psych::SyntaxError => e
    findings << "#{path}:#{e.line}: does not parse as YAML (#{e.problem}); GitHub would not run it either"
    next
  end
  next unless document.is_a?(Psych::Nodes::Document)
  anchors = {}
  document.each do |node|
    next if node.is_a?(Psych::Nodes::Alias)
    anchors[node.anchor] = node if node.respond_to?(:anchor) && node.anchor
  end
  root = resolve(document.root, anchors)
  next unless root.is_a?(Psych::Nodes::Mapping)
  jobs = entry(root, "jobs")
  jobs = jobs && resolve(jobs[1], anchors)
  next unless jobs.is_a?(Psych::Nodes::Mapping)
  jobs.children.each_slice(2) do |_name, job|
    job = resolve(job, anchors)
    next unless job.is_a?(Psych::Nodes::Mapping)
    runs_on = entry(job, "runs-on")
    next unless runs_on
    next if lists_self_hosted?(runs_on[1], anchors)
    next unless scalars(runs_on[1], anchors).any? { |label| exposes_setting?(label) }
    findings << "#{path}:#{runs_on[0].start_line + 1}: runs-on can take its label from a setting (vars) that is not wrapped with the self-hosted label, so the setting could name a GitHub-hosted image; wrap every such reference as fromJSON(format('[\"self-hosted\",\"{0}\"]', vars.NAME))"
  end
end

if findings.empty?
  puts "hosted-runner check: #{files.length} workflow file(s), no GitHub-hosted macOS or Windows runner."
  exit 0
end
findings.each { |finding| warn finding }
warn "hosted-runner check: refused. Route macOS and Windows work to a self-hosted runner that a setting names, with the self-hosted label required, or remove it."
exit 1
RUBY
