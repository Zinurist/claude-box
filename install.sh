#!/bin/sh
set -eu

BASHRC=${BASHRC:-$HOME/.bashrc}
BEGIN='# >>> agent-box >>>'
END='# <<< agent-box <<<'
update_bashrc=1

for arg in "$@"; do
  case $arg in
    --no-bashrc) update_bashrc=0 ;;
    *) echo "usage: $0 [--no-bashrc]" >&2; exit 2 ;;
  esac
done

podman build -t agent-box .

mkdir -p "$HOME/.local/bin"
cp agent-box-lib.sh "$HOME/.local/bin/agent-box-lib.sh"
for tool in claude opencode pi; do
  cp "$tool-box" "$HOME/.local/bin/$tool-box"
  chmod +x "$HOME/.local/bin/$tool-box"
done
echo "installed: claude-box, opencode-box, pi-box"

[ "$update_bashrc" -eq 1 ] || exit 0

# Locate the real, un-boxed binary for a tool. PATH first, so an nvm node
# upgrade is picked up automatically on the next run; then known install
# locations. The wrappers are named *-box, so they never shadow these.
find_raw() {
  found=$(command -v "$1" 2>/dev/null || true)
  if [ -n "$found" ] && [ -x "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  for candidate in $2; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

[ -e "$BASHRC" ] || : > "$BASHRC"
# Keep the pre-install original around; don't clobber it on later runs.
[ -e "$BASHRC.agent-box.bak" ] || cp "$BASHRC" "$BASHRC.agent-box.bak"

block=$(
  printf '%s\n' "$BEGIN"
  printf '%s\n' "# Managed by agent-box install.sh; this block is rewritten on each run."
  printf '%s\n' "# Re-run ./install.sh to refresh the -raw paths (e.g. after a node upgrade)."
  for tool in claude opencode pi; do
    printf "alias %s='%s-box'\n" "$tool" "$tool"
    case $tool in
      claude) candidates="$HOME/.local/bin/claude $HOME/.claude/local/claude" ;;
      opencode) candidates="$HOME/.opencode/bin/opencode" ;;
      pi) candidates=$(ls -d "$HOME"/.nvm/versions/node/*/bin/pi 2>/dev/null | tr '\n' ' ') ;;
    esac
    if raw=$(find_raw "$tool" "$candidates"); then
      printf "alias %s-raw='%s'\n" "$tool" "$raw"
    else
      printf '%s\n' "# $tool-raw: no un-boxed $tool found on PATH at install time"
      echo "warning: no un-boxed '$tool' found; skipping $tool-raw alias" >&2
    fi
  done
  printf '%s\n' "$END"
)

# Drop any previous managed block, plus stray hand-written aliases for the same
# names, then re-append. Keeps the file idempotent across runs.
tmp=$(mktemp)
awk -v b="$BEGIN" -v e="$END" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  skip { next }
  /^[[:space:]]*alias[[:space:]]+(claude|opencode|pi)(-raw)?=/ { next }
  { kept[++n] = $0 }
  END {
    # Drop trailing blank lines so re-runs do not accumulate them.
    while (n > 0 && kept[n] ~ /^[[:space:]]*$/) n--
    for (i = 1; i <= n; i++) print kept[i]
  }
' "$BASHRC" > "$tmp"

{
  cat "$tmp"
  printf '\n%s\n' "$block"
} > "$BASHRC"
rm -f "$tmp"

echo "updated $BASHRC (original saved as $BASHRC.agent-box.bak)"
echo "run 'source $BASHRC' or open a new shell to pick up the aliases"
