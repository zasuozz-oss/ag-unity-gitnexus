/**
 * Unity Analyze Command
 *
 * Smart Unity project indexing with auto SDK detection and interactive config.
 * Usage: gitnexus unity analyze [path] [options]
 */

import path from 'path';
import readline from 'readline';
import {
  isUnityProject,
  scanUnityAssets,
  loadUnityConfig,
  saveUnityConfig,
  createUnityIgnoreFilter,
  type UnityConfig,
  type ScannedFolder,
} from '../config/unity-preset.js';
import { getStoragePaths } from '../storage/repo-manager.js';
import { getGitRoot, isGitRepo } from '../storage/git.js';
import { execFileSync } from 'child_process';
import v8 from 'v8';

const HEAP_MB = 8192;
const HEAP_FLAG = `--max-old-space-size=${HEAP_MB}`;

/** Re-exec the process with an 8GB heap if we're currently below that. */
function ensureHeap(): boolean {
  const nodeOpts = process.env.NODE_OPTIONS || '';
  if (nodeOpts.includes('--max-old-space-size')) return false;

  const v8Heap = v8.getHeapStatistics().heap_size_limit;
  if (v8Heap >= HEAP_MB * 1024 * 1024 * 0.9) return false;

  try {
    execFileSync(process.execPath, [HEAP_FLAG, ...process.argv.slice(1)], {
      stdio: 'inherit',
      env: { ...process.env, NODE_OPTIONS: `${nodeOpts} ${HEAP_FLAG}`.trim() },
    });
  } catch (e: any) {
    process.exitCode = e.status ?? 1;
  }
  return true;
}

function hasUnityRelevantChanges(repoPath: string): boolean {
  try {
    const status = execFileSync(
      'git',
      ['status', '--porcelain', '--', 'Assets', 'ProjectSettings', 'Packages'],
      { cwd: repoPath, encoding: 'utf-8' },
    ).trim();
    return status.length > 0;
  } catch {
    return false;
  }
}

export interface UnityAnalyzeOptions {
  force?: boolean;
  embeddings?: boolean;
  dropEmbeddings?: boolean;
  skills?: boolean;
  skipAgentsMd?: boolean;
  stats?: boolean;
  resetConfig?: boolean;
  verbose?: boolean;
  maxFileSize?: string;
  workerTimeout?: string;
}

/** Ask a question via readline and return the answer */
function ask(rl: readline.Interface, question: string): Promise<string> {
  return new Promise(resolve => rl.question(question, resolve));
}

/**
 * Display folder classification and automatically return config without user interaction.
 */
function autoConfig(
  folders: ScannedFolder[],
): { ignored: string[]; included: string[] } {
  const ignored = new Set<string>();
  const included = new Set<string>();

  // Initial classification
  for (const f of folders) {
    if (f.category === 'sdk' || f.category === 'asset-only') {
      ignored.add(f.name);
    } else {
      included.add(f.name);
    }
  }

  const ignoredFolders = folders.filter(f => ignored.has(f.name));
  const includedFolders = folders.filter(f => included.has(f.name));

  if (ignoredFolders.length > 0) {
    console.log(`\n  Auto-ignored (${ignoredFolders.length} folders):`);
    for (const f of ignoredFolders) {
      const desc = f.category === 'sdk' ? f.description : (f.csFileCount > 0 ? `${f.csFileCount} .cs files` : 'No code');
      console.log(`    \x1b[31m✗\x1b[0m ${f.name.padEnd(28)} (${desc})`);
    }
  }

  if (includedFolders.length > 0) {
    console.log(`\n  Will be indexed (${includedFolders.length} folders):`);
    for (const f of includedFolders) {
      const desc = f.csFileCount > 0 ? `${f.csFileCount} .cs files` : 'No code';
      console.log(`    \x1b[32m✓\x1b[0m ${f.name.padEnd(28)} (${desc})`);
    }
  }

  return {
    ignored: Array.from(ignored).sort(),
    included: Array.from(included).sort(),
  };
}

export const unityAnalyzeCommand = async (
  inputPath?: string,
  options?: UnityAnalyzeOptions,
) => {
  if (ensureHeap()) return;

  if (options?.verbose) {
    process.env.GITNEXUS_VERBOSE = '1';
  }

  console.log('\n  GitNexus Unity Analyzer\n');

  // Resolve repo path
  let repoPath: string;
  if (inputPath) {
    repoPath = path.resolve(inputPath);
  } else {
    const gitRoot = getGitRoot(process.cwd());
    if (!gitRoot) {
      console.log('  Not inside a git repository\n');
      process.exitCode = 1;
      return;
    }
    repoPath = gitRoot;
  }

  if (!isGitRepo(repoPath)) {
    console.log('  Not a git repository\n');
    process.exitCode = 1;
    return;
  }

  // Verify Unity project
  if (!(await isUnityProject(repoPath))) {
    console.log('  Not a Unity project (missing Assets/ or ProjectSettings/)\n');
    process.exitCode = 1;
    return;
  }

  const projectName = path.basename(repoPath);
  console.log(`  Detected Unity project: ${projectName}\n`);

  const { storagePath } = getStoragePaths(repoPath);

  // Load or create config
  let config: UnityConfig | null = null;
  let configChanged = false;

  if (!options?.resetConfig) {
    config = await loadUnityConfig(storagePath);
  }

  if (config) {
    // Existing config — check for new folders
    console.log('  Loaded config from unity.json');

    const folders = await scanUnityAssets(repoPath);
    const knownFolders = new Set([...config.ignored, ...config.included]);
    const newFolders = folders.filter(f => !knownFolders.has(f.name));

    if (newFolders.length > 0) {
      console.log(`\n  ⚠ New folders detected:`);
      for (const f of newFolders) {
        const action = f.category === 'game' ? 'indexed' : 'ignored';
        const symbol = f.category === 'game' ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m';
        console.log(`    ${symbol} ${f.name} → ${action} (${f.description})`);
        if (f.category === 'game') {
          config.included.push(f.name);
        } else {
          config.ignored.push(f.name);
        }
      }
      console.log('  (edit unity.json to change)\n');
      config.lastScanAt = new Date().toISOString();
      await saveUnityConfig(storagePath, config);
      configChanged = true;
    }

    // Show summary
    if (options?.verbose) {
      console.log(`  Ignored: ${config.ignored.length} folders`);
      console.log(`  Indexed: ${config.included.length} folders\n`);
    }
  } else {
    // First run — scan and interactive config
    console.log('  Scanning Assets/...');
    const folders = await scanUnityAssets(repoPath);

    if (folders.length === 0) {
      console.log('  No subfolders found in Assets/\n');
      process.exitCode = 1;
      return;
    }

    const result = autoConfig(folders);

    config = {
      ...result,
      lastScanAt: new Date().toISOString(),
    };

    await saveUnityConfig(storagePath, config);
    console.log(`\n  Config saved to .gitnexus/unity.json`);
    configChanged = true;
  }

  // Create Unity ignore filter and run analyze
  const unityIgnoreFilter = await createUnityIgnoreFilter(repoPath, config);

  console.log('');

  const { analyzeCommand } = await import('./analyze.js');
  const shouldForceAnalyze = Boolean(
    options?.force ||
    options?.embeddings ||
    options?.dropEmbeddings ||
    options?.resetConfig ||
    configChanged ||
    hasUnityRelevantChanges(repoPath),
  );
  await analyzeCommand(repoPath, {
    force: shouldForceAnalyze,
    embeddings: options?.embeddings,
    dropEmbeddings: options?.dropEmbeddings,
    skills: options?.skills,
    skipAgentsMd: options?.skipAgentsMd,
    stats: options?.stats,
    verbose: options?.verbose,
    maxFileSize: options?.maxFileSize,
    workerTimeout: options?.workerTimeout,
    ignoreFilter: unityIgnoreFilter,
    projectType: 'unity',
  });
};
