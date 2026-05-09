#compdef touchstone

_touchstone() {
  local -a commands
  commands=(
    'init:Add touchstone to the current project'
    'new:Bootstrap a new project from scratch'
    'update:Create a branch and commit for touchstone updates'
    'update-all:Update all registered projects'
    'sync:Deprecated alias for update-all'
    'status:Show project status (use --all for the registry view)'
    'doctor:Check project or installation health'
    'review-stats:Report conductor-review fail-open trends'
    'preflight:Run deterministic review preflight checks'
    'version:Show installed version'
    'list:Show registered projects'
    'unregister:Remove a project from the registry'
    'diff:Compare project files against latest templates'
    'adr:Create or list Architecture Decision Records'
    'release:Cut a new touchstone release (maintainer)'
    'help:Show help'
  )

  _arguments -C \
    '1:command:->command' \
    '*::arg:->args'

  case "$state" in
    command)
      _describe 'touchstone command' commands
      ;;
    args)
      case "$words[1]" in
        init)
          _arguments \
            '--no-setup[Bootstrap files without running setup.sh]' \
            '--no-register[Do not add the project to ~/.touchstone-projects]' \
            '--type[Project type]:project type:(auto node python swift rust go generic)' \
            '--unsafe-paths[Comma-separated high-scrutiny paths]:paths:' \
            '--reviewer[AI reviewer]:reviewer:(auto codex claude gemini local none)' \
            '--no-ai-review[Disable AI review]' \
            '--no-review[Disable AI review]' \
            '--review-assist[Allow one peer reviewer second opinion]' \
            '--no-review-assist[Disable peer reviewer assistance]' \
            '--review-autofix[Allow low-risk auto-fixes]' \
            '--no-review-autofix[Disable auto-fixes]' \
            '--local-review-command[Command that reads review prompt on stdin]:command:'
          ;;
        new)
          _arguments \
            '1:project directory:_directories' \
            '--no-register[Do not add the project to ~/.touchstone-projects]' \
            '--type[Project type]:project type:(auto node python swift rust go generic)' \
            '--unsafe-paths[Comma-separated high-scrutiny paths]:paths:' \
            '--reviewer[AI reviewer]:reviewer:(auto codex claude gemini local none)' \
            '--no-ai-review[Disable AI review]' \
            '--no-review[Disable AI review]' \
            '--review-assist[Allow one peer reviewer second opinion]' \
            '--no-review-assist[Disable peer reviewer assistance]' \
            '--review-autofix[Allow low-risk auto-fixes]' \
            '--no-review-autofix[Disable auto-fixes]' \
            '--local-review-command[Command that reads review prompt on stdin]:command:'
          ;;
        update)
          _arguments \
            '--dry-run[Preview changes without applying]' \
            '--check[Report whether this project needs update]' \
            '--in-place[Commit the update on the current branch]' \
            '--no-branch[Alias for --in-place]' \
            '--ship[Push, open PR, review, and auto-merge]' \
            '--no-ship[Do not run the shipping flow]' \
            '--branch[Use a specific update branch]:branch name:'
          ;;
        update-all|sync)
          _arguments \
            '--pull-first[Pull latest touchstone before updating projects]' \
            '--check[Report which projects need update]' \
            '--dry-run[Preview updates without applying]'
          ;;
        status)
          _arguments \
            '--all[Show version distribution across registered projects]'
          ;;
        doctor)
          _arguments \
            '--project[Check per-project health]' \
            '--require-capability[Require a project-local workflow capability]:capability:' \
            '--installation[Check touchstone installation health]'
          ;;
        review-stats)
          _arguments \
            '--log-path[Read a fixture or alternate review log]:log path:_files' \
            '--threshold[Warn when last-7d fail-open rate exceeds this percent]:percent:'
          ;;
        unregister)
          # Complete from registered projects.
          local -a projects
          if [ -f "$HOME/.touchstone-projects" ]; then
            projects=(${(f)"$(cat "$HOME/.touchstone-projects" 2>/dev/null)"})
          fi
          _describe 'project' projects
          ;;
        adr)
          _arguments \
            '1:subcommand:(list)' \
            '*:title:'
          ;;
        release)
          _arguments \
            '--major[Major version bump]' \
            '--minor[Minor version bump (default)]' \
            '--patch[Patch version bump]'
          ;;
      esac
      ;;
  esac
}

_touchstone "$@"
