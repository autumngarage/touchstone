_touchstone() {
  local cur prev commands
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="init new update update-all sync status doctor version list unregister diff adr release preflight help"

  case "$prev" in
    touchstone)
      COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
      ;;
    init|new)
      COMPREPLY=( $(compgen -W "--no-register --type --skip-language-scaffold --gitbutler --no-gitbutler --gitbutler-mcp --no-gitbutler-mcp --ci --scaffold-tests --with-cortex --no-with-cortex --with-sentinel --no-with-sentinel --initial-commit --no-initial-commit --github-private --github-public --no-github" -- "$cur") )
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
    unregister)
      if [ -f "$HOME/.touchstone-projects" ]; then
        COMPREPLY=( $(compgen -W "$(cat "$HOME/.touchstone-projects" 2>/dev/null)" -- "$cur") )
      fi
      ;;
    adr)
      COMPREPLY=( $(compgen -W "list" -- "$cur") )
      ;;
    release)
      COMPREPLY=( $(compgen -W "--major --minor --patch --finalize" -- "$cur") )
      ;;
  esac
}

complete -F _touchstone touchstone
