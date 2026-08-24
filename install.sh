#!/bin/sh
# claude-with installer
# Installs the claude-with binary
set -e

VERSION="0.1.0"
REPO_URL="https://raw.githubusercontent.com/KakkoiDev/claude-with/main"

# Detect local vs remote (curl | sh) mode
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/claude-with" ]; then
  LOCAL_MODE=1
  CW_SOURCE="$SCRIPT_DIR/claude-with"
else
  LOCAL_MODE=0
  CW_SOURCE=""
fi

# Defaults
INSTALL_DIR=""
SKIP_DEPS=0
UNINSTALL=0

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  RESET='\033[0m'
else
  GREEN="" RED="" YELLOW="" RESET=""
fi

info()  { printf "${GREEN}[+]${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$1"; }
error() { printf "${RED}[x]${RESET} %s\n" "$1" >&2; }
die()   { error "$1"; exit 1; }

usage() {
  cat <<EOF
claude-with installer v${VERSION}

Usage: ./install.sh [OPTIONS]

Options:
  --dir PATH        Install directory (default: ~/.local/bin or /usr/local/bin)
  --skip-deps       Skip dependency checks
  --uninstall       Remove claude-with
  --help            Show this help

Examples:
  ./install.sh                # Install claude-with
  ./install.sh --dir ~/bin    # Install to custom directory
  ./install.sh --uninstall    # Remove
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        INSTALL_DIR="$2"; shift 2 ;;
    --skip-deps)  SKIP_DEPS=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --help)       usage ;;
    *)            die "Unknown option: $1" ;;
  esac
done

resolve_install_dir() {
  if [ -n "$INSTALL_DIR" ]; then
    return
  fi

  if [ -d "$HOME/.local/bin" ]; then
    INSTALL_DIR="$HOME/.local/bin"
  elif [ -w /usr/local/bin ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="$HOME/.local/bin"
  fi
}

check_deps() {
  if [ "$SKIP_DEPS" = 1 ]; then
    warn "Skipping dependency checks"
    return
  fi

  missing=""
  command -v bash >/dev/null 2>&1    || missing="$missing bash"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"

  if [ -n "$missing" ]; then
    die "Missing dependencies:$missing"
  fi

  if ! command -v claude >/dev/null 2>&1; then
    warn "claude CLI not found. claude-with wraps 'claude' and will fail until Claude Code is installed."
  fi
}

download() {
  _dl_url="$1" _dl_dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$_dl_url" -o "$_dl_dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$_dl_dest" "$_dl_url"
  else
    die "curl or wget required for remote install"
  fi
}

install_claude_with() {
  mkdir -p "$INSTALL_DIR"

  if [ "$LOCAL_MODE" = 1 ]; then
    cp "$CW_SOURCE" "$INSTALL_DIR/claude-with"
  else
    info "Downloading claude-with from GitHub..."
    download "$REPO_URL/claude-with" "$INSTALL_DIR/claude-with"
  fi

  chmod +x "$INSTALL_DIR/claude-with"
  info "Installed claude-with to $INSTALL_DIR/claude-with"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
      warn "$INSTALL_DIR is not in your PATH"
      warn "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
  esac
}

uninstall() {
  resolve_install_dir

  if [ -f "$INSTALL_DIR/claude-with" ]; then
    rm "$INSTALL_DIR/claude-with"
    info "Removed $INSTALL_DIR/claude-with"
  else
    warn "claude-with not found at $INSTALL_DIR/claude-with"
  fi

  info "Uninstall complete"
  exit 0
}

if [ "$UNINSTALL" = 1 ]; then
  uninstall
fi

resolve_install_dir
check_deps
install_claude_with

info "claude-with v${VERSION} installed successfully"
info "Next: run 'claude-with --help' or 'claude-with --dry-run' to see it in action"
