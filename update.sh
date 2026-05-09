#!/usr/bin/env bash
# GitNexus upstream update for the local embedded repo.
# Configures MCP for Antigravity, Claude CLI, and Codex CLI.
# Cross-platform: macOS, Linux, and Windows (Git Bash / MSYS2 / WSL).
#
# Usage: ./update.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}-- $* --${NC}"; }

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
    # Verify it's Python 3.x
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

# ── rsync-like helper (falls back to cp on Windows) ──────────
sync_dir() {
  local src="$1"
  local dst="$2"
  shift 2
  # remaining args are --exclude patterns

  if command -v rsync &>/dev/null; then
    rsync -a --delete "$@" "$src" "$dst"
  else
    # Fallback: remove destination then copy, respecting excludes
    # Collect exclude patterns into an array
    local excludes=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --exclude=*) excludes+=("${1#--exclude=}") ; shift ;;
        --exclude)   excludes+=("$2") ; shift 2 ;;
        *)           shift ;;
      esac
    done

    # On Windows without rsync, use Python for robust sync
    $PYTHON - "$src" "$dst" "${excludes[@]}" <<'PYSYNC'
import shutil, sys, os
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
excludes = sys.argv[3:]

def should_exclude(rel_path):
    """Check if a relative path matches any exclude pattern."""
    rel_str = str(rel_path).replace('\\', '/')
    for exc in excludes:
        exc = exc.strip('/')
        # Exact match or prefix match
        if rel_str == exc or rel_str.startswith(exc + '/'):
            return True
        # Match basename
        if '/' not in exc and rel_path.name == exc:
            return True
    return False

# Collect files to copy
src_files = set()
for path in src.rglob('*'):
    rel = path.relative_to(src)
    if should_exclude(rel):
        continue
    src_files.add(rel)

# Remove files in dst that are not in src (--delete behavior)
if dst.exists():
    for path in sorted(dst.rglob('*'), reverse=True):
        rel = path.relative_to(dst)
        if should_exclude(rel):
            continue
        if rel not in src_files:
            if path.is_file():
                path.unlink()
            elif path.is_dir() and not any(path.iterdir()):
                path.rmdir()

# Copy files from src to dst
dst.mkdir(parents=True, exist_ok=True)
for rel in sorted(src_files):
    s = src / rel
    d = dst / rel
    if s.is_dir():
        d.mkdir(parents=True, exist_ok=True)
    elif s.is_file():
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(s), str(d))
PYSYNC
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITNEXUS_DIR="$SCRIPT_DIR/GitNexus"
GITNEXUS_CLI_DIR="$GITNEXUS_DIR/gitnexus"
GITNEXUS_SHARED_DIR="$GITNEXUS_DIR/gitnexus-shared"
GITNEXUS_WEB_DIR="$GITNEXUS_DIR/gitnexus-web"
GITNEXUS_SKILLS_DIR="$GITNEXUS_CLI_DIR/skills"
CUSTOM_UNITY_DIR="$SCRIPT_DIR/custom/gitnexus-unity"
CUSTOM_SKILLS_DIR="$SCRIPT_DIR/custom/skills"
ANTIGRAVITY_SKILLS_DIR="$HOME/.gemini/antigravity/skills"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
CLAUDE_CLI_MCP="$HOME/.claude.json"
CODEX_CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
UPSTREAM_REPO="https://github.com/abhigyanpatwari/GitNexus.git"
TMP_DIR=""

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

check_prereqs() {
  step "Checking prerequisites"

  detect_python

  for cmd in git node npm; do
    if ! command -v "$cmd" &>/dev/null; then
      err "$cmd not found"
      exit 1
    fi
    ok "$cmd available"
  done

  ok "$PYTHON available"

  # rsync is optional on Windows — we have a fallback
  if command -v rsync &>/dev/null; then
    ok "rsync available"
  else
    if [ "$OS" = "windows" ]; then
      warn "rsync not found — using Python-based sync (slower but works)"
    else
      err "rsync not found (install via: brew install rsync / apt install rsync)"
      exit 1
    fi
  fi

  local node_major
  node_major=$(node -v | sed 's/v//' | cut -d. -f1)
  if (( node_major < 20 )); then
    err "Node >= 20 required (found $(node -v))"
    exit 1
  fi
}

ensure_layout() {
  if [ ! -d "$GITNEXUS_DIR" ]; then
    err "GitNexus directory not found at $GITNEXUS_DIR"
    info "Run ./setup.sh first"
    exit 1
  fi

  if [ ! -d "$GITNEXUS_CLI_DIR" ]; then
    err "GitNexus CLI directory not found at $GITNEXUS_CLI_DIR"
    exit 1
  fi
}

sync_upstream() {
  step "Syncing upstream GitNexus"

  TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'gitnexus-update')"
  info "Cloning $UPSTREAM_REPO"
  git clone --depth 1 "$UPSTREAM_REPO" "$TMP_DIR" >/dev/null 2>&1

  info "Updating $GITNEXUS_DIR"
  sync_dir "$TMP_DIR/" "$GITNEXUS_DIR/" \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='gitnexus/node_modules' \
    --exclude='gitnexus/vendor/tree-sitter-dart/build' \
    --exclude='gitnexus/vendor/tree-sitter-proto/build' \
    --exclude='gitnexus-shared/node_modules' \
    --exclude='gitnexus-web/node_modules'

  ok "Upstream files synced"
}

apply_unity_command_patch() {
  step "Applying local Unity command customizations"

  local custom_unity_cli="$CUSTOM_UNITY_DIR/src/cli/unity-analyze.ts"
  local custom_unity_preset="$CUSTOM_UNITY_DIR/src/config/unity-preset.ts"
  if [ ! -f "$custom_unity_cli" ] || [ ! -f "$custom_unity_preset" ]; then
    err "Custom Unity files are missing from $CUSTOM_UNITY_DIR"
    exit 1
  fi

  local unity_cli="$GITNEXUS_CLI_DIR/src/cli/unity-analyze.ts"
  local unity_preset="$GITNEXUS_CLI_DIR/src/config/unity-preset.ts"
  mkdir -p "$(dirname "$unity_cli")" "$(dirname "$unity_preset")"
  cp "$custom_unity_cli" "$unity_cli"
  cp "$custom_unity_preset" "$unity_preset"

  $PYTHON - "$GITNEXUS_CLI_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def read(rel: str) -> str:
    return (root / rel).read_text()

def write(rel: str, text: str) -> None:
    (root / rel).write_text(text)

def replace_once(text: str, old: str, new: str, file_name: str) -> str:
    if old not in text:
        return text
    return text.replace(old, new, 1)

index = read("src/cli/index.ts")
unity_block = """// --- Unity Project Tools -------------------------------------------------
const unity = program.command('unity').description('Unity project tools');

unity
  .command('analyze [path]')
  .description('Index a Unity project with smart SDK detection')
  .option('-f, --force', 'Force full re-index')
  .option('--embeddings', 'Enable embedding generation')
  .option(
    '--drop-embeddings',
    'Drop existing embeddings on rebuild. By default, Unity analysis preserves existing embeddings.',
  )
  .option('--skills', 'Deprecated no-op; GitNexus skills are installed globally by setup')
  .option('--skip-agents-md', 'Skip updating the gitnexus section in AGENTS.md and CLAUDE.md')
  .option('--no-stats', 'Omit volatile file/symbol counts from AGENTS.md and CLAUDE.md')
  .option('--reset-config', 'Reset unity.json and re-scan')
  .option('-v, --verbose', 'Verbose output')
  .option(
    '--max-file-size <kb>',
    'Skip files larger than this (KB). Default: 512. Hard cap: 32768 (tree-sitter limit).',
  )
  .option(
    '--worker-timeout <seconds>',
    'Worker sub-batch idle timeout before retry/fallback. Default: 30.',
  )
  .action(createLazyAction(() => import('./unity-analyze.js'), 'unityAnalyzeCommand'));

"""
if "command('unity')" not in index:
    marker = "  .action(createLazyAction(() => import('./analyze.js'), 'analyzeCommand'));\n\n"
    if marker not in index:
        raise SystemExit("Cannot patch src/cli/index.ts: analyze command marker not found")
    index = index.replace(marker, marker + unity_block, 1)
index = index.replace(
    ".option('--skills', 'Generate repo-specific skill files from detected communities')",
    ".option('--skills', 'Deprecated no-op; GitNexus skills are installed globally by setup')",
)
write("src/cli/index.ts", index)

walker = read("src/core/ingestion/filesystem-walker.ts")
walker = replace_once(
    walker,
    "export const walkRepositoryPaths = async (\n  repoPath: string,\n  onProgress?: (current: number, total: number, filePath: string) => void,\n): Promise<ScannedFile[]> => {",
    "export const walkRepositoryPaths = async (\n  repoPath: string,\n  onProgress?: (current: number, total: number, filePath: string) => void,\n  customIgnoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean },\n): Promise<ScannedFile[]> => {",
    "src/core/ingestion/filesystem-walker.ts",
)
walker = replace_once(
    walker,
    "  const ignoreFilter = await createIgnoreFilter(repoPath);",
    "  const ignoreFilter = customIgnoreFilter ?? (await createIgnoreFilter(repoPath));",
    "src/core/ingestion/filesystem-walker.ts",
)
write("src/core/ingestion/filesystem-walker.ts", walker)

pipeline = read("src/core/ingestion/pipeline.ts")
if "ignoreFilter?: { ignored:" not in pipeline:
    pipeline = replace_once(
        pipeline,
        "  /** Force sequential parsing (no worker pool). Useful for testing the sequential path. */\n  skipWorkers?: boolean;\n",
        "  /** Force sequential parsing (no worker pool). Useful for testing the sequential path. */\n  skipWorkers?: boolean;\n  /** Custom ignore filter, used by project-specific commands such as Unity analysis. */\n  ignoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean };\n",
        "src/core/ingestion/pipeline.ts",
    )
write("src/core/ingestion/pipeline.ts", pipeline)

scan = read("src/core/ingestion/pipeline-phases/scan.ts")
if "ctx.options?.ignoreFilter" not in scan:
    old = """    const scannedFiles = await walkRepositoryPaths(ctx.repoPath, (current, total, filePath) => {
      const scanProgress = Math.round((current / total) * 15);
      ctx.onProgress({
        phase: 'extracting',
        percent: scanProgress,
        message: 'Scanning repository...',
        detail: filePath,
        stats: {
          filesProcessed: current,
          totalFiles: total,
          nodesCreated: ctx.graph.nodeCount,
        },
      });
    });"""
    new = """    const scannedFiles = await walkRepositoryPaths(
      ctx.repoPath,
      (current, total, filePath) => {
        const scanProgress = Math.round((current / total) * 15);
        ctx.onProgress({
          phase: 'extracting',
          percent: scanProgress,
          message: 'Scanning repository...',
          detail: filePath,
          stats: {
            filesProcessed: current,
            totalFiles: total,
            nodesCreated: ctx.graph.nodeCount,
          },
        });
      },
      ctx.options?.ignoreFilter,
    );"""
    if old not in scan:
        raise SystemExit("Cannot patch scan.ts: walkRepositoryPaths marker not found")
    scan = scan.replace(old, new, 1)
write("src/core/ingestion/pipeline-phases/scan.ts", scan)

run_analyze = read("src/core/run-analyze.ts")
run_analyze = run_analyze.replace(
    "if (existingMeta && !options.force && existingMeta.lastCommit === currentCommit) {",
    "if (\n"
    "    existingMeta &&\n"
    "    !options.force &&\n"
    "    !options.embeddings &&\n"
    "    !options.dropEmbeddings &&\n"
    "    existingMeta.lastCommit === currentCommit\n"
    "  ) {",
)
if "ignoreFilter?: { ignored:" not in run_analyze:
    run_analyze = replace_once(
        run_analyze,
        "  dropEmbeddings?: boolean;\n  skipGit?: boolean;\n",
        "  dropEmbeddings?: boolean;\n  skipGit?: boolean;\n  /** Custom ignore filter, used by project-specific commands such as Unity analysis. */\n  ignoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean };\n",
        "src/core/run-analyze.ts",
    )
if "projectType?:" not in run_analyze:
    run_analyze = replace_once(
        run_analyze,
        "  /** Skip AGENTS.md and CLAUDE.md gitnexus block updates. */\n  skipAgentsMd?: boolean;\n",
        "  /** Skip AGENTS.md and CLAUDE.md gitnexus block updates. */\n  skipAgentsMd?: boolean;\n  /** Project type hint for generated AI context (e.g. 'unity'). */\n  projectType?: string;\n",
        "src/core/run-analyze.ts",
    )
if "{ ignoreFilter: options.ignoreFilter }" not in run_analyze:
    old = """  const pipelineResult = await runPipelineFromRepo(repoPath, (p) => {
    const phaseLabel = PHASE_LABELS[p.phase] || p.phase;
    const scaled = Math.round(p.percent * 0.6);
    const message = p.detail ? `${p.message || phaseLabel} (${p.detail})` : p.message || phaseLabel;
    progress(p.phase, scaled, message);
  });"""
    new = """  const pipelineResult = await runPipelineFromRepo(
    repoPath,
    (p) => {
      const phaseLabel = PHASE_LABELS[p.phase] || p.phase;
      const scaled = Math.round(p.percent * 0.6);
      const message = p.detail
        ? `${p.message || phaseLabel} (${p.detail})`
        : p.message || phaseLabel;
      progress(p.phase, scaled, message);
    },
    { ignoreFilter: options.ignoreFilter },
  );"""
    if old not in run_analyze:
        raise SystemExit("Cannot patch run-analyze.ts: runPipelineFromRepo marker not found")
    run_analyze = run_analyze.replace(old, new, 1)
# Patch generateAIContextFiles call to pass projectType
if "projectType: options.projectType" not in run_analyze:
    run_analyze = run_analyze.replace(
        "        { skipAgentsMd: options.skipAgentsMd, noStats: options.noStats },",
        "        { skipAgentsMd: options.skipAgentsMd, noStats: options.noStats, projectType: options.projectType },",
    )
write("src/core/run-analyze.ts", run_analyze)

analyze = read("src/cli/analyze.ts")
analyze = analyze.replace(
    " * skill generation (--skills), summary output, and process.exit().",
    " * backward-compatible --skills handling, summary output, and process.exit().",
)
analyze = analyze.replace("  getStoragePaths,\n  getGlobalRegistryPath,\n", "  getGlobalRegistryPath,\n")
analyze = analyze.replace(
    "// Note: --skills is handled after runFullAnalysis using the returned pipelineResult.",
    "// Note: --skills is kept as a backward-compatible no-op. GitNexus skills are\n"
    "  // installed globally by setup, not generated into each project.",
)
if "ignoreFilter?: { ignored:" not in analyze:
    analyze = replace_once(
        analyze,
        "  /** Index the folder even when no .git directory is present. */\n  skipGit?: boolean;\n",
        "  /** Index the folder even when no .git directory is present. */\n  skipGit?: boolean;\n  /** Custom ignore filter, used by project-specific commands such as Unity analysis. */\n  ignoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean };\n",
        "src/cli/analyze.ts",
    )
if "projectType?:" not in analyze:
    analyze = replace_once(
        analyze,
        "  ignoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean };\n",
        "  ignoreFilter?: { ignored: (p: any) => boolean; childrenIgnored: (p: any) => boolean };\n  /** Project type hint for generated AI context (e.g. 'unity'). */\n  projectType?: string;\n",
        "src/cli/analyze.ts",
    )
if "ignoreFilter: options?.ignoreFilter" not in analyze:
    analyze = replace_once(
        analyze,
        "        skipGit: options?.skipGit,\n",
        "        skipGit: options?.skipGit,\n        ignoreFilter: options?.ignoreFilter,\n",
        "src/cli/analyze.ts",
    )
if "projectType: options?.projectType" not in analyze:
    analyze = replace_once(
        analyze,
        "        ignoreFilter: options?.ignoreFilter,\n",
        "        ignoreFilter: options?.ignoreFilter,\n        projectType: options?.projectType,\n",
        "src/cli/analyze.ts",
    )
analyze = analyze.replace("        force: options?.force || options?.skills,\n", "        force: options?.force,\n")
skill_block_marker = "    // Skill generation (CLI-only, uses pipeline result from analysis)\n    if (options?.skills && result.pipelineResult) {"
if skill_block_marker in analyze:
    start = analyze.index(skill_block_marker)
    end_marker = "\n\n    const totalTime ="
    end = analyze.index(end_marker, start)
    analyze = (
        analyze[:start]
        + "    if (options?.skills) {\n"
        + "      updateBar(99, 'Skipping project skill generation...');\n"
        + "      barLog('  --skills is deprecated: GitNexus skills are installed globally by setup.');\n"
        + "    }"
        + analyze[end:]
    )
# Normalize npx references to local binary in error messages
analyze = analyze.replace("npx gitnexus@latest analyze", "gitnexus analyze")
analyze = analyze.replace("npx gitnexus@latest", "gitnexus")
write("src/cli/analyze.ts", analyze)

ai_context = read("src/cli/ai-context.ts")
ai_context = ai_context.replace("import { fileURLToPath } from 'url';\n", "")
ai_context = ai_context.replace(
    "\n// ESM equivalent of __dirname\n"
    "const __filename = fileURLToPath(import.meta.url);\n"
    "const __dirname = path.dirname(__filename);\n",
    "",
)
skills_table_start = ai_context.find("  const generatedRows =\n")
if skills_table_start != -1:
    skills_table_end = ai_context.find("\n\n  return `${GITNEXUS_START_MARKER}", skills_table_start)
    if skills_table_end == -1:
        raise SystemExit("Cannot patch ai-context.ts: skills table end marker not found")
    ai_context = (
        ai_context[:skills_table_start]
        + "  void generatedSkills;\n\n"
        + "  const skillsTable = `| Task | Use this global skill |\n"
        + "|------|-----------------------|\n"
        + "| Understand architecture / \"How does X work?\" | \\`gitnexus-exploring\\` |\n"
        + "| Blast radius / \"What breaks if I change X?\" | \\`gitnexus-impact-analysis\\` |\n"
        + "| Trace bugs / \"Why is X failing?\" | \\`gitnexus-debugging\\` |\n"
        + "| Rename / extract / split / refactor | \\`gitnexus-refactoring\\` |\n"
        + "| Tools, resources, schema reference | \\`gitnexus-guide\\` |\n"
        + "| Index, status, clean, wiki CLI commands | \\`gitnexus-cli\\` |`;"
        + ai_context[skills_table_end:]
    )
install_start = ai_context.find("/**\n * Install GitNexus skills to .claude/skills/gitnexus/")
if install_start != -1:
    install_end = ai_context.find("/**\n * Generate AI context files after indexing", install_start)
    if install_end == -1:
        raise SystemExit("Cannot patch ai-context.ts: installSkills end marker not found")
    ai_context = ai_context[:install_start] + ai_context[install_end:]
project_install_block = """  // Install skills to .claude/skills/gitnexus/
  const installedSkills = await installSkills(repoPath);
  if (installedSkills.length > 0) {
    createdFiles.push(`.claude/skills/gitnexus/ (${installedSkills.length} skills)`);
  }

"""
ai_context = ai_context.replace(project_install_block, "")

# --- Add projectType support to AIContextOptions ---
if "projectType?:" not in ai_context:
    ai_context = ai_context.replace(
        "  noStats?: boolean;\n}",
        "  noStats?: boolean;\n  /** Project type hint (e.g. 'unity') — changes re-index command in generated content. */\n  projectType?: string;\n}",
    )

# --- Add projectType param to generateGitNexusContent ---
if "projectType?:" not in ai_context.split("function generateGitNexusContent")[1].split("): string")[0] if "function generateGitNexusContent" in ai_context else "":
    ai_context = ai_context.replace(
        "  noStats?: boolean,\n): string {",
        "  noStats?: boolean,\n  projectType?: string,\n): string {",
    )

# --- Replace hardcoded 'gitnexus analyze' with projectType-aware command ---
if "const analyzeCmd =" not in ai_context:
    ai_context = ai_context.replace(
        "): string {\n  void generatedSkills;",
        "): string {\n  const analyzeCmd = projectType === 'unity' ? 'gitnexus unity analyze' : 'gitnexus analyze';\n  void generatedSkills;",
    )
    # Replace the hardcoded gitnexus analyze in the stale-index warning
    ai_context = ai_context.replace(
        "> If any GitNexus tool warns the index is stale, run \\`gitnexus analyze\\` in terminal first.",
        "> If any GitNexus tool warns the index is stale, run \\`${analyzeCmd}\\` in terminal first.",
    )

# --- Pass projectType through generateAIContextFiles ---
if "options?.projectType" not in ai_context:
    ai_context = ai_context.replace(
        "    groupNames,\n    options?.noStats,\n  );",
        "    groupNames,\n    options?.noStats,\n    options?.projectType,\n  );",
    )

write("src/cli/ai-context.ts", ai_context)
PY

  ok "Unity custom files copied and command patch applied"
}

apply_cli_command_patch() {
  step "Applying local CLI command customizations"

  local patched
  patched=$($PYTHON - "$SCRIPT_DIR" "$GITNEXUS_DIR" "$CUSTOM_SKILLS_DIR" <<'PY'
from pathlib import Path
import re
import sys

script_dir = Path(sys.argv[1])
gitnexus_dir = Path(sys.argv[2])
custom_skills_dir = Path(sys.argv[3])

text_suffixes = {
    ".cjs",
    ".js",
    ".json",
    ".md",
    ".mjs",
    ".ts",
    ".tsx",
}

roots = [
    script_dir / "AGENTS.md",
    script_dir / "CLAUDE.md",
    custom_skills_dir,
    gitnexus_dir / ".claude" / "skills" / "gitnexus",
    gitnexus_dir / "AGENTS.md",
    gitnexus_dir / "CHANGELOG.md",
    gitnexus_dir / "GUARDRAILS.md",
    gitnexus_dir / "MIGRATION.md",
    gitnexus_dir / "README.md",
    gitnexus_dir / "RUNBOOK.md",
    gitnexus_dir / "docs" / "guides" / "microservices-grpc.md",
    gitnexus_dir / "gitnexus" / "README.md",
    gitnexus_dir / "gitnexus" / "dist" / "cli",
    gitnexus_dir / "gitnexus" / "dist" / "mcp",
    gitnexus_dir / "gitnexus" / "hooks" / "claude",
    gitnexus_dir / "gitnexus" / "skills",
    gitnexus_dir / "gitnexus" / "src" / "cli",
    gitnexus_dir / "gitnexus" / "src" / "mcp",
    gitnexus_dir / "gitnexus" / "test" / "integration" / "hooks-e2e.test.ts",
    gitnexus_dir / "gitnexus-claude-plugin" / "hooks",
    gitnexus_dir / "gitnexus-claude-plugin" / "skills",
    gitnexus_dir / "gitnexus-cursor-integration" / "skills",
]

def iter_files(root: Path):
    if not root.exists():
        return
    if root.is_file():
        if root.suffix in text_suffixes:
            yield root
        return
    for path in root.rglob("*"):
        if path.is_file() and path.suffix in text_suffixes:
            yield path

def normalize(text: str) -> str:
    text = re.sub(r"\bnpx gitnexus(?!@)", "gitnexus", text)
    text = text.replace("`gitnexus`, `gitnexus`, or", "`gitnexus` or")
    text = text.replace("`gitnexus` or `gitnexus`", "`gitnexus`")
    return text

patched = 0
seen: set[Path] = set()
for root in roots:
    for path in iter_files(root):
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        try:
            original = path.read_text()
        except UnicodeDecodeError:
            continue
        updated = normalize(original)
        if updated != original:
            path.write_text(updated)
            patched += 1

print(patched)
PY
)

  ok "CLI command references normalized to gitnexus ($patched files)"
}

configure_claude_cli() {
  step "Configuring Claude CLI MCP"

  if ! command -v claude &>/dev/null; then
    warn "Claude CLI not installed — skipping"
    return
  fi

  if [ -z "$PYTHON" ]; then
    warn "Python 3 not found — add manually to $CLAUDE_CLI_MCP"
    return
  fi

  [ -s "$CLAUDE_CLI_MCP" ] || echo '{"mcpServers":{}}' > "$CLAUDE_CLI_MCP"

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
" "$CLAUDE_CLI_MCP")

  case "$action" in
    added)     ok "Claude CLI MCP entry added" ;;
    updated)   ok "Claude CLI MCP entry updated" ;;
    unchanged) ok "Claude CLI MCP already configured" ;;
  esac
}

# ── Configure Codex CLI MCP ──────────────────────────────────
configure_codex() {
  step "Configuring Codex CLI MCP"

  local codex_config="$CODEX_CONFIG_DIR/config.toml"

  if [ ! -d "$CODEX_CONFIG_DIR" ]; then
    warn "Codex CLI not installed — skipping"
    return
  fi

  if [ -z "$PYTHON" ]; then
    warn "Python 3 not found — add gitnexus MCP manually to $codex_config"
    return
  fi

  [ -f "$codex_config" ] || touch "$codex_config"

  local action
  action=$($PYTHON -c "
import sys

config_path = sys.argv[1]
with open(config_path) as f:
    lines = f.readlines()

section_start = -1
section_end = len(lines)
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('[') and not stripped.startswith('[\"') and not stripped.startswith(\"['\"):
        if stripped == '[mcp_servers.gitnexus]':
            section_start = i
        elif section_start >= 0:
            section_end = i
            break

if section_start >= 0:
    section_lines = lines[section_start+1:section_end]
    has_correct_cmd = any('command' in l and '\"gitnexus\"' in l and 'npx' not in l for l in section_lines)
    has_correct_args = any('args' in l and '\"mcp\"' in l and 'gitnexus' not in l for l in section_lines)
    if has_correct_cmd and has_correct_args:
        print('unchanged')
        sys.exit(0)

    new_section = ['command = \"gitnexus\"\n', 'args = [ \"mcp\" ]\n']
    for line in section_lines:
        stripped = line.strip()
        if stripped.startswith('command =') or stripped.startswith('args ='):
            continue
        if stripped.startswith('[\"') or stripped.startswith(\"['\"):
            continue
        new_section.append(line)
    lines[section_start+1:section_end] = new_section
    print('updated')
else:
    lines.append('\n[mcp_servers.gitnexus]\ncommand = \"gitnexus\"\nargs = [ \"mcp\" ]\n')
    print('added')

with open(config_path, 'w') as f:
    f.writelines(lines)
" "$codex_config")

  case "$action" in
    added)     ok "Codex CLI MCP entry added" ;;
    updated)   ok "Codex CLI MCP entry updated" ;;
    unchanged) ok "Codex CLI MCP already configured" ;;
  esac
}

apply_custom_skills() {
  [ -d "$CUSTOM_SKILLS_DIR" ] || return 0

  shopt -s nullglob
  local skill_file skill_name installed=0
  for skill_file in "$CUSTOM_SKILLS_DIR"/*.md; do
    skill_name="$(basename "$skill_file" .md)"

    # Override in upstream skills dir (picked up by install_global_skills in setup.sh)
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

install_dependencies() {
  step "Installing dependencies"

  if [ -d "$GITNEXUS_SHARED_DIR" ]; then
    (cd "$GITNEXUS_SHARED_DIR" && npm install)
    ok "Shared dependencies installed"
  fi

  if [ -d "$GITNEXUS_WEB_DIR" ]; then
    (cd "$GITNEXUS_WEB_DIR" && npm install)
    ok "Web UI dependencies installed"
  fi

  (cd "$GITNEXUS_CLI_DIR" && npm install)
  ok "CLI dependencies installed"
}

build_and_link_cli() {
  step "Building and linking CLI"

  local old_ver
  old_ver=$(gitnexus --version 2>/dev/null || echo "unknown")

  (cd "$GITNEXUS_CLI_DIR" && npm run build && npm link >/dev/null 2>&1)

  local new_ver
  new_ver=$(gitnexus --version 2>/dev/null || echo "unknown")
  if [ "$old_ver" = "$new_ver" ]; then
    ok "CLI rebuilt (v${new_ver})"
  else
    ok "CLI updated: v${old_ver} -> v${new_ver}"
  fi
}

main() {
  if [ "${1:-}" = "--apply-custom-only" ]; then
    detect_python
    ensure_layout
    apply_unity_command_patch
    apply_cli_command_patch
    apply_custom_skills
    configure_claude_cli
    configure_codex
    return
  fi

  echo -e "\n${CYAN}GitNexus upstream update${NC}"

  check_prereqs
  ensure_layout
  sync_upstream
  apply_unity_command_patch
  apply_cli_command_patch
  apply_custom_skills
  configure_claude_cli
  configure_codex
  install_dependencies
  build_and_link_cli

  echo ""
  echo -e "${GREEN}Update complete${NC}"
  echo -e "  ${DIM}Unity${NC}    gitnexus unity analyze --embeddings"
  echo -e "  ${DIM}Generic${NC}  gitnexus analyze --embeddings"
  echo -e "  ${DIM}Web UI${NC}   ./web-ui.sh"
}

main "$@"
