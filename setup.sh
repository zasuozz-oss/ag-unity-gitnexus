#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# GitNexus MCP — auto setup for Antigravity, Claude CLI, and Codex CLI
# Cross-platform: macOS, Linux, and Windows (Git Bash / MSYS2 / WSL).
#
# Install:  ./setup.sh
# Update:   ./update.sh
# ══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}── $* ──${NC}"; }

# ── OS detection ─────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin)       OS="macos"   ;;
    Linux)        OS="linux"   ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *)            OS="unknown" ;;
  esac
}
detect_os

# ── Python wrapper (python3 on macOS/Linux, python on Windows) ──
PYTHON=""
detect_python() {
  if command -v python3 &>/dev/null; then
    PYTHON="python3"
  elif command -v python &>/dev/null; then
    local py_ver
    py_ver=$(python -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "2")
    if [ "$py_ver" = "3" ]; then
      PYTHON="python"
    fi
  fi
  if [ -z "$PYTHON" ]; then
    err "Python 3 not found (tried python3 and python)"
    exit 1
  fi
}

# ── rsync wrapper (falls back to cp -r on Windows) ───────────
sync_skill_dir() {
  local src="$1"
  local dst="$2"
  if command -v rsync &>/dev/null; then
    rsync -a "$src" "$dst"
  else
    cp -r "$src"* "$dst/" 2>/dev/null || cp -r "$src". "$dst/" 2>/dev/null || true
  fi
}

# ── Config ───────────────────────────────────────────────────
ANTIGRAVITY_MCP="$HOME/.gemini/antigravity/mcp_config.json"
CLAUDE_CLI_MCP="$HOME/.claude.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITNEXUS_DIR="$SCRIPT_DIR/GitNexus"
GITNEXUS_WEB_DIR="$GITNEXUS_DIR/gitnexus-web"
GITNEXUS_CLI_DIR="$GITNEXUS_DIR/gitnexus"
GITNEXUS_SHARED_DIR="$GITNEXUS_DIR/gitnexus-shared"
GITNEXUS_SKILLS_DIR="$GITNEXUS_CLI_DIR/skills"
ANTIGRAVITY_SKILLS_DIR="$HOME/.gemini/antigravity/skills"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
CUSTOM_SKILLS_DIR="$SCRIPT_DIR/custom/skills"
UPSTREAM_REPO="https://github.com/abhigyanpatwari/GitNexus.git"

# ── Prereqs ──────────────────────────────────────────────────
check_prereqs() {
  step "Checking prerequisites"

  detect_python

  if ! command -v node &>/dev/null; then
    err "Node.js not found. Install Node >= 20 first."; exit 1
  fi
  local node_major
  node_major=$(node -v | sed 's/v//' | cut -d. -f1)
  if (( node_major < 20 )); then
    err "Node >= 20 required (found $(node -v))"; exit 1
  fi
  ok "Node $(node -v)"

  if ! command -v npm &>/dev/null; then
    err "npm not found (should come with Node.js)"; exit 1
  fi
  ok "npm available"

  if ! command -v git &>/dev/null; then
    err "git not found"; exit 1
  fi
  ok "git available"

  # rsync is optional on Windows — we have fallbacks
  if command -v rsync &>/dev/null; then
    ok "rsync available"
  else
    if [ "$OS" = "windows" ]; then
      warn "rsync not found — using fallback copy (works but slower)"
    else
      err "rsync not found (install via: brew install rsync / apt install rsync)"
      exit 1
    fi
  fi

  ok "$PYTHON available"
}

# ── Configure Antigravity MCP ────────────────────────────────
configure_mcp() {
  step "Configuring Antigravity MCP"

  if [ -z "$PYTHON" ]; then
    warn "Python 3 not found — add manually to $ANTIGRAVITY_MCP:"
    cat << 'EOF'
  "gitnexus": {
    "command": "gitnexus",
    "args": ["mcp"]
  }
EOF
    return
  fi

  mkdir -p "$(dirname "$ANTIGRAVITY_MCP")"
  [ -s "$ANTIGRAVITY_MCP" ] || echo '{"mcpServers":{}}' > "$ANTIGRAVITY_MCP"

  local action
  action=$($PYTHON -c "
import json, sys

path = sys.argv[1]

with open(path) as f:
    cfg = json.load(f)

servers = cfg.setdefault('mcpServers', {})
expected = {
    'command': 'gitnexus',
    'args': ['mcp']
}
existing = servers.get('gitnexus')

if existing == expected:
    print('unchanged')
    sys.exit(0)

action = 'updated' if existing else 'added'
servers['gitnexus'] = expected

with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')

print(action)
" "$ANTIGRAVITY_MCP")

  case "$action" in
    added)     ok "MCP entry added" ;;
    updated)   ok "MCP entry updated" ;;
    unchanged) ok "MCP already configured" ;;
  esac

  info "MCP command: gitnexus mcp (linked from local fork)"
}



# ── Configure editors via upstream gitnexus setup ─────────────
# Upstream `gitnexus setup` natively configures:
#   - Cursor, Claude Code, OpenCode, Codex (MCP)
#   - Skills installation for all editors
#   - Claude Code hooks (PreToolUse, PostToolUse)
# We only keep Antigravity MCP config as custom (not supported upstream).
configure_editors() {
  step "Configuring editor MCP via gitnexus setup"

  if ! command -v gitnexus &>/dev/null; then
    warn "gitnexus CLI not available yet — skipping editor config"
    info "Run ./setup.sh again after build to configure editors"
    return
  fi

  if gitnexus setup; then
    ok "Editor MCP configured via gitnexus setup"
  else
    warn "gitnexus setup failed — editors may need manual MCP config"
  fi
}

# ── Install Global Skills ───────────────────────────────────
install_skills_to() {
  local target_dir="$1"
  local label="$2"
  local installed=0

  mkdir -p "$target_dir"

  shopt -s nullglob
  local skill_file
  for skill_file in "$GITNEXUS_SKILLS_DIR"/*.md; do
    local skill_name
    skill_name="$(basename "$skill_file" .md)"
    mkdir -p "$target_dir/$skill_name"
    cp "$skill_file" "$target_dir/$skill_name/SKILL.md"
    installed=$((installed + 1))
  done

  local skill_dir
  for skill_dir in "$GITNEXUS_SKILLS_DIR"/*/; do
    [ -f "$skill_dir/SKILL.md" ] || continue
    local skill_name
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$target_dir/$skill_name"
    # Use rsync if available, otherwise cp -r
    if command -v rsync &>/dev/null; then
      rsync -a "$skill_dir/" "$target_dir/$skill_name/"
    else
      cp -r "$skill_dir"* "$target_dir/$skill_name/" 2>/dev/null || true
      # Ensure hidden files are also copied
      cp -r "$skill_dir".* "$target_dir/$skill_name/" 2>/dev/null || true
    fi
    installed=$((installed + 1))
  done
  shopt -u nullglob

  if [ "$installed" -eq 0 ]; then
    warn "No GitNexus skills found for $label"
  else
    ok "$label global skills synced ($installed skills → $target_dir)"
  fi
}

install_global_skills() {
  step "Installing GitNexus global skills"

  if [ ! -d "$GITNEXUS_SKILLS_DIR" ]; then
    warn "GitNexus skills directory not found at $GITNEXUS_SKILLS_DIR"
    return
  fi

  install_skills_to "$ANTIGRAVITY_SKILLS_DIR" "Antigravity"
  install_skills_to "$CLAUDE_SKILLS_DIR" "Claude"
  install_skills_to "$CODEX_SKILLS_DIR" "Codex"
}

# ── Apply custom skill overrides ─────────────────────────────
apply_custom_skills() {
  [ -d "$CUSTOM_SKILLS_DIR" ] || return 0

  shopt -s nullglob
  local skill_file skill_name installed=0
  for skill_file in "$CUSTOM_SKILLS_DIR"/*.md; do
    skill_name="$(basename "$skill_file" .md)"

    # Override in upstream skills dir for future install_global_skills runs
    mkdir -p "$GITNEXUS_SKILLS_DIR"
    cp "$skill_file" "$GITNEXUS_SKILLS_DIR/$skill_name.md"

    # Deploy directly to each agent's skills dir
    for target in "$CLAUDE_SKILLS_DIR" "$ANTIGRAVITY_SKILLS_DIR" "$CODEX_SKILLS_DIR"; do
      mkdir -p "$target/$skill_name"
      cp "$skill_file" "$target/$skill_name/SKILL.md"
    done

    installed=$((installed + 1))
  done
  shopt -u nullglob

  [ "$installed" -gt 0 ] && ok "Custom skills overlaid ($installed skills)"
}

# ── Fork/clone GitNexus for Web UI ────────────────────────────
fork_web_ui() {
  step "Setting up GitNexus Web UI"

  if [ -d "$GITNEXUS_WEB_DIR" ]; then
    ok "GitNexus already cloned at $GITNEXUS_DIR"
    info "To update the embedded GitNexus repo, run ./update.sh"
    return
  fi

  mkdir -p "$GITNEXUS_DIR"

  if command -v gh &>/dev/null; then
    info "Forking abhigyanpatwari/GitNexus via GitHub CLI..."
    if (cd "$SCRIPT_DIR" && gh repo fork abhigyanpatwari/GitNexus --clone=true 2>&1); then
      ok "Forked and cloned → $GITNEXUS_DIR"
    else
      warn "Fork failed — falling back to clone"
      git clone https://github.com/abhigyanpatwari/GitNexus.git "$GITNEXUS_DIR"
      ok "Cloned → $GITNEXUS_DIR"
    fi
  else
    info "gh CLI not found — cloning directly..."
    git clone https://github.com/abhigyanpatwari/GitNexus.git "$GITNEXUS_DIR"
    ok "Cloned → $GITNEXUS_DIR"
  fi

  # Install web UI dependencies
  if [ -d "$GITNEXUS_WEB_DIR" ]; then
    step "Installing Web UI dependencies"
    (cd "$GITNEXUS_WEB_DIR" && npm install 2>&1)
    ok "Web UI dependencies installed"
  else
    warn "gitnexus-web/ not found in cloned repo"
  fi
}

# ── Apply local GitNexus customizations ──────────────────────
apply_gitnexus_customizations() {
  step "Applying local GitNexus customizations"

  # On Windows (Git Bash), scripts may not be marked executable
  if [ "$OS" = "windows" ]; then
    if [ ! -f "$SCRIPT_DIR/update.sh" ]; then
      warn "update.sh not found — skipping local customizations"
      return
    fi
  else
    if [ ! -x "$SCRIPT_DIR/update.sh" ]; then
      warn "update.sh not found or not executable — skipping local customizations"
      return
    fi
  fi

  info "Delegating upstream-safe patches to update.sh --apply-custom-only"
  bash "$SCRIPT_DIR/update.sh" --apply-custom-only
  ok "Local GitNexus customizations applied"
}

# ── Build & Link Local CLI ───────────────────────────────────
setup_cli_build() {
  step "Building and Linking GitNexus CLI"
  local cli_dir="$GITNEXUS_DIR/gitnexus"
  local shared_dir="$GITNEXUS_DIR/gitnexus-shared"
  local web_dir="$GITNEXUS_DIR/gitnexus-web"
  if [ -d "$cli_dir" ]; then
    info "Installing dependencies, building, and linking globally..."
    if [ -d "$shared_dir" ]; then
      (cd "$shared_dir" && npm install)
    fi
    if [ -d "$web_dir" ]; then
      (cd "$web_dir" && npm install)
    fi
    if (cd "$cli_dir" && npm install && npm run build && npm link > /dev/null 2>&1); then
      ok "CLI built and linked. You can now use the 'gitnexus' command everywhere."
    else
      warn "Failed to build or link CLI."
    fi
  else
    warn "CLI directory $cli_dir not found"
  fi
}

main() {
  echo -e "\n${CYAN}🔧 GitNexus MCP setup${NC}"

  check_prereqs
  fork_web_ui
  apply_gitnexus_customizations
  setup_cli_build

  # Configure MCP AFTER build so gitnexus binary is available
  configure_mcp          # Antigravity (custom, not supported upstream)
  configure_editors      # Claude Code, Codex, Cursor, OpenCode (via gitnexus setup)

  # Custom skills overlay (on top of what gitnexus setup installed)
  apply_custom_skills

  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Setup complete!${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${DIM}Index Unity${NC}    cd your-project && gitnexus unity analyze --embeddings"
  echo -e "  ${DIM}Index generic${NC}  cd your-project && gitnexus analyze"
  echo -e "  ${DIM}Web UI${NC}         ./web-ui.sh"
  echo -e "  ${DIM}Update${NC}         ./update.sh"
  echo -e "  ${DIM}Re-run setup${NC}   ./setup.sh"
  echo ""
  echo -e "  ${YELLOW}→ Restart Antigravity, Claude Code, and Codex to load MCP${NC}"
  echo ""
}

# ── Entry point ──────────────────────────────────────────────
case "${1:-}" in
  --update|-u)
    exec "$SCRIPT_DIR/update.sh"
    ;;
  --help|-h)
    echo "Usage: ./setup.sh"
    echo ""
    echo "  ./setup.sh    Full setup (first install)"
    echo "  ./update.sh   Pull upstream & rebuild local CLI"
    ;;
  "")
    main
    ;;
  *)
    err "Unknown option: $1"
    echo "Usage: ./setup.sh"
    exit 1
    ;;
esac
