#!/usr/bin/env bash
# Install a local Squad marketplace and a stable, checkout-backed CLI link.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<'EOF'
Usage: ./install.sh codex|claude-code [--bin-dir DIR] [--cli-only]

Installs the plugin from this checkout and links the squad command into
~/.local/bin. Keep this checkout: the command and local marketplace use it.
No sudo, shell-profile edits, project changes or recovery services are applied.
Use --cli-only if you already installed the plugin through its marketplace.
Update: git pull --ff-only, then rerun this command.
EOF
}
case "${1:-}" in -h|--help|'') usage; exit 0 ;; codex|claude-code) harness="$1"; shift ;; *) usage >&2; exit 2 ;; esac
bin_dir="$HOME/.local/bin"
cli_only=0
while (($#)); do
  case "$1" in
    --bin-dir) [[ -n "${2:-}" ]] || { usage >&2; exit 2; }; bin_dir="$2"; shift 2 ;;
    --cli-only) cli_only=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo 'Squad currently supports Linux only.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Install Python >= 3.10 first.' >&2; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo 'Python >= 3.10 is required.' >&2; exit 1; }
# Refuse to overwrite an unrelated command, including a dangling symlink.
if [[ -e "$bin_dir/squad" || -L "$bin_dir/squad" ]]; then
  [[ -L "$bin_dir/squad" && "$(readlink -f "$bin_dir/squad")" == "$ROOT/bin/squad" ]] || {
    echo "An unrelated command exists at $bin_dir/squad; choose --bin-dir." >&2; exit 1;
  }
fi
if (( ! cli_only )); then
  if [[ "$harness" == codex ]]; then
    command -v codex >/dev/null || { echo 'Install and sign in to Codex first.' >&2; exit 1; }
    codex plugin marketplace add "$ROOT"
    codex plugin add squad@squad
  else
    command -v claude >/dev/null || { echo 'Install and sign in to Claude Code first.' >&2; exit 1; }
    claude plugin marketplace add "$ROOT"
    claude plugin install squad@squad --scope user
  fi
fi
mkdir -p "$bin_dir"
ln -sfn "$ROOT/bin/squad" "$bin_dir/squad"
printf 'Installed squad at %s/squad\n' "$bin_dir"
case ":$PATH:" in *":$bin_dir:"*) ;; *) printf 'Add that directory to PATH. For this shell: export PATH="%s:$PATH"\n' "$bin_dir" ;; esac
printf 'Next: squad --harness %s doctor\nStart a fresh harness session and invoke the Squad init skill.\n' "$harness"
