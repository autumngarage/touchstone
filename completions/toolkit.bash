_toolkit() {
  local cur prev commands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="init new update sync status doctor version list unregister diff adr release help"

  case "$prev" in
    toolkit)
      COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
      ;;
    new)
      COMPREPLY=( $(compgen -d -- "$cur") )
      ;;
    update)
      COMPREPLY=( $(compgen -W "--dry-run --check --branch" -- "$cur") )
      ;;
    sync)
      COMPREPLY=( $(compgen -W "--pull-first" -- "$cur") )
      ;;
    unregister)
      if [ -f "$HOME/.toolkit-projects" ]; then
        COMPREPLY=( $(compgen -W "$(cat "$HOME/.toolkit-projects" 2>/dev/null)" -- "$cur") )
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

complete -F _toolkit toolkit
