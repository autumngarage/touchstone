_touchstone() {
  local cur prev commands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="init new update update-all sync status doctor review-stats version list unregister diff adr release preflight help"

  case "$prev" in
    touchstone)
      COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
      ;;
    init|new)
      COMPREPLY=( $(compgen -W "--no-register --type --unsafe-paths --reviewer --no-ai-review --no-review --review-assist --no-review-assist --review-autofix --no-review-autofix --local-review-command" -- "$cur") )
      ;;
    update)
      COMPREPLY=( $(compgen -W "--dry-run --check --branch" -- "$cur") )
      ;;
    update-all|sync)
      COMPREPLY=( $(compgen -W "--pull-first --check --dry-run" -- "$cur") )
      ;;
    status)
      COMPREPLY=( $(compgen -W "--all" -- "$cur") )
      ;;
    doctor)
      COMPREPLY=( $(compgen -W "--project --installation --require-capability" -- "$cur") )
      ;;
    review-stats)
      COMPREPLY=( $(compgen -W "--log-path --threshold" -- "$cur") )
      ;;
    unregister)
      if [ -f "$HOME/.touchstone-projects" ]; then
        COMPREPLY=( $(compgen -W "$(cat "$HOME/.touchstone-projects" 2>/dev/null)" -- "$cur") )
      fi
      ;;
    adr)
      COMPREPLY=( $(compgen -W "list" -- "$cur") )
      ;;
    release)
      COMPREPLY=( $(compgen -W "--major --minor --patch" -- "$cur") )
      ;;
  esac
}

complete -F _touchstone touchstone
