#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# Launch GitNexus Web UI (backend + frontend)
#
# Usage:  ./web-ui.sh
# ══════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$SCRIPT_DIR/GitNexus/gitnexus-web"

cleanup() {
  trap - EXIT INT TERM # fix terminated loop
  echo -e "\n${CYAN}Shutting down...${NC}"
  kill 0 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

# ── Checks ───────────────────────────────────────────────────
if [ ! -d "$WEB_DIR" ]; then
  echo -e "${RED}[ERROR]${NC} GitNexus not found. Run ./setup.sh first."
  exit 1
fi

if [ ! -d "$WEB_DIR/node_modules" ]; then
  echo -e "${YELLOW}[INFO]${NC}  Installing dependencies..."
  (cd "$WEB_DIR" && npm install)
fi

# ── Launch ───────────────────────────────────────────────────
echo -e "${CYAN}🚀 Starting GitNexus Web UI${NC}\n"

echo -e "${GREEN}  Backend${NC}   → http://127.0.0.1:4747"
echo -e "${GREEN}  Frontend${NC}  → http://localhost:5173"
echo -e ""
echo -e "${YELLOW}  Press Ctrl+C to stop both${NC}\n"

# Start backend (API server) from the locally linked GitNexus CLI.
gitnexus serve &

# Start frontend (Vite dev server)
(cd "$WEB_DIR" && npm run dev) &

# Wait for both
wait
