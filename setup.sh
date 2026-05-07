#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# GitNexus MCP — auto setup for Antigravity, Claude CLI, and Codex CLI
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

  if ! command -v rsync &>/dev/null; then
    err "rsync not found"; exit 1
  fi
  ok "rsync available"

  if ! command -v python3 &>/dev/null; then
    err "python3 not found"; exit 1
  fi
  ok "python3 available"
}

# ── Configure Antigravity MCP ────────────────────────────────
configure_mcp() {
  step "Configuring Antigravity MCP"

  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — add manually to $ANTIGRAVITY_MCP:"
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
  action=$(python3 -c "
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



# ── Configure Claude CLI MCP ─────────────────────────────────
configure_claude_cli() {
  step "Configuring Claude CLI MCP"

  if ! command -v claude &>/dev/null; then
    warn "Claude CLI not installed — skipping"
    return
  fi

  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — add manually to $CLAUDE_CLI_MCP"
    return
  fi

  [ -s "$CLAUDE_CLI_MCP" ] || echo '{"mcpServers":{}}' > "$CLAUDE_CLI_MCP"

  local action
  action=$(python3 -c "
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
" "$CLAUDE_CLI_MCP")

  case "$action" in
    added)     ok "Claude CLI MCP entry added" ;;
    updated)   ok "Claude CLI MCP entry updated" ;;
    unchanged) ok "Claude CLI MCP already configured" ;;
  esac
}

# ── Configure Codex MCP ──────────────────────────────────────
configure_codex() {
  step "Configuring Codex MCP"

  local codex_dir="$HOME/.codex"
  local codex_config="$codex_dir/config.toml"

  if [ ! -d "$codex_dir" ]; then
    warn "Codex not installed — skipping"
    return
  fi

  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — add gitnexus MCP manually to $codex_config"
    return
  fi

  # Ensure config.toml exists
  [ -f "$codex_config" ] || touch "$codex_config"

  local action
  action=$(python3 -c "
import sys

config_path = sys.argv[1]
with open(config_path) as f:
    lines = f.readlines()

# Parse: find [mcp_servers.gitnexus] section boundaries
section_start = -1
section_end = len(lines)
for i, line in enumerate(lines):
    stripped = line.strip()
    # Match section header: starts with [ but NOT array values like [\"foo\"]
    if stripped.startswith('[') and not stripped.startswith('[\"') and not stripped.startswith(\"['\"):
        if stripped == '[mcp_servers.gitnexus]':
            section_start = i
        elif section_start >= 0:
            # Found next section after our target
            section_end = i
            break

if section_start >= 0:
    # Check if already correct
    section_lines = lines[section_start+1:section_end]
    section_text = ''.join(section_lines)
    has_correct_cmd = any('command' in l and '\"gitnexus\"' in l and 'npx' not in l for l in section_lines)
    has_correct_args = any('args' in l and '\"mcp\"' in l and 'gitnexus' not in l for l in section_lines)
    if has_correct_cmd and has_correct_args:
        print('unchanged')
        sys.exit(0)

    # Replace command/args, keep other keys (env, tools, etc.)
    new_section = ['command = \"gitnexus\"\n', 'args = [ \"mcp\" ]\n']
    for line in section_lines:
        stripped = line.strip()
        if stripped.startswith('command =') or stripped.startswith('args ='):
            continue
        # Skip orphan array lines from previous bad runs
        if stripped.startswith('[\"') or stripped.startswith(\"['\"):
            continue
        new_section.append(line)
    lines[section_start+1:section_end] = new_section
    print('updated')
else:
    # Add new section
    lines.append('\n[mcp_servers.gitnexus]\ncommand = \"gitnexus\"\nargs = [ \"mcp\" ]\n')
    print('added')

with open(config_path, 'w') as f:
    f.writelines(lines)
" "$codex_config")

  case "$action" in
    added)     ok "Codex MCP entry added" ;;
    updated)   ok "Codex MCP entry updated (now uses local fork)" ;;
    unchanged) ok "Codex MCP already configured" ;;
  esac
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
    rsync -a "$skill_dir/" "$target_dir/$skill_name/"
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

  if [ ! -x "$SCRIPT_DIR/update.sh" ]; then
    warn "update.sh not found or not executable — skipping local customizations"
    return
  fi

  "$SCRIPT_DIR/update.sh" --apply-custom-only
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

# ── Main ─────────────────────────────────────────────────────
main() {
  echo -e "\n${CYAN}🔧 GitNexus MCP setup${NC}"

  check_prereqs
  configure_mcp
  configure_claude_cli
  configure_codex
  fork_web_ui
  install_global_skills
  apply_custom_skills
  apply_gitnexus_customizations
  setup_cli_build

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
  echo -e "  ${YELLOW}→ Restart Antigravity, Claude CLI, and Codex CLI to load MCP${NC}"
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
