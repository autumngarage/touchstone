#compdef toolkit

_toolkit() {
  local -a commands
  commands=(
    'init:Add toolkit to the current project'
    'new:Bootstrap a new project from scratch'
    'update:Update current project to latest toolkit'
    'sync:Update all registered projects'
    'status:Dashboard — health of all projects'
    'doctor:Check toolkit installation health'
    'version:Show installed version'
    'list:Show registered projects'
    'unregister:Remove a project from the registry'
    'diff:Compare project files against latest templates'
    'adr:Create or list Architecture Decision Records'
    'release:Cut a new toolkit release (maintainer)'
    'help:Show help'
  )

  _arguments -C \
    '1:command:->command' \
    '*::arg:->args'

  case "$state" in
    command)
      _describe 'toolkit command' commands
      ;;
    args)
      case "$words[1]" in
        new)
          _arguments '1:project directory:_directories'
          ;;
        update)
          _arguments '--dry-run[Preview changes without applying]'
          ;;
        sync)
          _arguments '--pull-first[Pull latest toolkit before syncing]'
          ;;
        unregister)
          # Complete from registered projects.
          local -a projects
          if [ -f "$HOME/.toolkit-projects" ]; then
            projects=(${(f)"$(cat "$HOME/.toolkit-projects" 2>/dev/null)"})
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

_toolkit "$@"
