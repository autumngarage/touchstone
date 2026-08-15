# shellcheck shell=bash

tasks_for_python() {
  local directory="$1" target="$2" suffix="$3" prefix="python -m" found=false evidence=false uv_version uv_guard
  if [ -f "$directory/pyproject.toml" ]; then
    validate_toml_document "$directory/pyproject.toml" pyproject.toml
  fi
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.poetry(\.|\])' "$directory/pyproject.toml" \
    && ! python_poetry_build_system_valid "$directory/pyproject.toml"; then
    contract_refusal "Python target '$target' declares Poetry metadata without a verified poetry-core build backend; pass --task NAME=COMMAND"
  fi
  if python_has_unverifiable_build_hook "$directory"; then
    contract_refusal "Python target '$target' declares a project build hook this portable compiler cannot verify offline; pass --task NAME=COMMAND"
  fi
  if python_has_environment_marker "$directory/pyproject.toml" "$directory/requirements.txt"; then
    contract_refusal "Python target '$target' contains an environment-marked dependency this portable compiler cannot verify; use unconditional locked dependencies or pass --task NAME=COMMAND"
  fi
  if python_has_remote_reference "$directory/pyproject.toml" "$directory/requirements.txt"; then
    contract_refusal "Python target '$target' contains a remote direct dependency reference or checkout-external source; use named dependencies from the offline lock source, or pass --task NAME=COMMAND"
  fi
  if [ -f "$directory/pyproject.toml" ]; then
    python_project_dependencies_valid "$directory/pyproject.toml" \
      || contract_refusal "Python target '$target' has a project dependency outside the supported named-requirement subset; pass --task NAME=COMMAND"
    python_has_uv_source_mapping "$directory/pyproject.toml" \
      && contract_refusal "Python target '$target' declares a uv source mapping this portable compiler cannot bind to tracked offline inputs; pass --task NAME=COMMAND"
  fi
  if [ -f "$directory/requirements.txt" ]; then
    validate_requirements_document "$directory/requirements.txt"
  fi
  [ -f "$directory/uv.lock" ] \
    || contract_refusal "Python automatic adoption requires uv.lock and an exact uv runtime so dependency setup is reproducible offline; pass --task NAME=COMMAND"
  if [ -f "$directory/uv.lock" ]; then
    [ -f "$directory/pyproject.toml" ] \
      || contract_refusal "uv automatic adoption requires pyproject.toml compatibility facts"
    validate_uv_lock "$directory/uv.lock" "$directory/pyproject.toml"
    uv_version="$(python_uv_version)"
    uv_guard="test \"\$(uv --version)\" = \"$uv_version\""
    verify_uv_lock_compatibility "$directory"
    prefix="$uv_guard && uv run --no-sync --no-config"
    if [ -f "$directory/pyproject.toml" ] && python_has_uv_dev_group "$directory/pyproject.toml"; then
      record_setup "$directory" "$uv_guard && uv sync --no-config --offline --frozen --group dev"
    else
      record_setup "$directory" "$uv_guard && uv sync --no-config --offline --frozen"
    fi
  fi
  evidence=false
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.ruff(\.|\])' "$directory/pyproject.toml"; then evidence=true; fi
  if python_checker_declared "$directory" ruff; then
    evidence=true
  elif [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' configures ruff without an installed ruff dependency"
  fi
  if [ "$evidence" = true ]; then
    record_task "lint$suffix" "$target" "$prefix ruff check ."
    found=true
  fi
  evidence=false
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.mypy(\.|\])' "$directory/pyproject.toml"; then evidence=true; fi
  if python_checker_declared "$directory" mypy; then
    evidence=true
  elif [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' configures mypy without an installed mypy dependency"
  fi
  if [ "$evidence" = true ] && ! python_has_tracked_source "$directory"; then
    contract_refusal "Python target '$target' has mypy evidence but no tracked regular Python source"
  fi
  if [ "$evidence" = true ]; then
    record_task "typecheck$suffix" "$target" "$prefix mypy ."
    found=true
  fi
  evidence=false
  if python_has_tracked_tests "$directory"; then evidence=true; fi
  if ! python_checker_declared "$directory" pytest && [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' has pytest evidence without an installed pytest dependency"
  fi
  if [ "$evidence" = true ]; then
    record_task "test$suffix" "$target" "$prefix pytest"
    found=true
  fi
  [ "$found" = true ] || contract_refusal "Python target '$target' has no declared ruff, mypy, or pytest evidence; pass --task NAME=COMMAND"
}
