#compdef touchstone

_touchstone() {
  local -a commands
  commands=(
    'init:Add touchstone to the current project'
    'new:Bootstrap a new project from scratch'
    'update:Create a branch and commit for touchstone updates'
    'sync:Update all registered projects'
    'status:Dashboard — health of all projects'
    'doctor:Check touchstone installation health'
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
            '--branch[Use a specific update branch]:branch name:'
          ;;
        sync)
          _arguments \
            '--pull-first[Pull latest touchstone before syncing]' \
            '--check[Report which projects need sync]' \
            '--dry-run[Preview updates without applying]'
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
