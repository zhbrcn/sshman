#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"

usage() {
  cat <<'EOF'
Usage:
  boot.sh --list
  boot.sh --run <name> [-- <args...>]
  boot.sh --all

Notes:
- Scripts are loaded from ./scripts/*.sh
- Order for --all is lexicographic; use numeric prefixes to control order.
EOF
}

list_scripts() {
  if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "scripts dir not found: $SCRIPTS_DIR" >&2
    return 1
  fi
  ls "$SCRIPTS_DIR"/*.sh 2>/dev/null | xargs -n1 basename | sed 's/\.sh$//' | sort
}

resolve_script() {
  local name="$1"
  local cand
  if [[ -z "$name" ]]; then
    return 1
  fi
  if [[ -f "$SCRIPTS_DIR/$name" ]]; then
    cand="$SCRIPTS_DIR/$name"
  else
    cand="$SCRIPTS_DIR/$name.sh"
  fi
  if [[ ! -f "$cand" ]]; then
    echo "script not found: $name" >&2
    return 1
  fi
  printf '%s' "$cand"
}

run_script() {
  local script="$1"
  shift
  if [[ ! -x "$script" ]]; then
    echo "script is not executable: $script" >&2
    return 1
  fi
  "$script" "$@"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 2
  fi

  case "$1" in
    --list)
      list_scripts
      ;;
    --run)
      shift
      local name="${1:-}"
      shift || true
      local args=()
      if [[ "${1:-}" == "--" ]]; then
        shift
        args=("$@")
      else
        args=("$@")
      fi
      local script
      script="$(resolve_script "$name")"
      run_script "$script" "${args[@]}"
      ;;
    --all)
      local scripts=()
      while IFS= read -r s; do
        scripts+=("$SCRIPTS_DIR/$s.sh")
      done < <(list_scripts)
      if [[ ${#scripts[@]} -eq 0 ]]; then
        echo "no scripts found in $SCRIPTS_DIR" >&2
        exit 1
      fi
      for script in "${scripts[@]}"; do
        run_script "$script"
      done
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"