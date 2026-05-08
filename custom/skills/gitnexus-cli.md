---
name: gitnexus-cli
description: "Use when running any GitNexus CLI operation — indexing, reindexing, checking status, clearing indexes, generating wiki/context files, or listing indexed repos. Also when `.gitnexus/` is missing or stale. Mandatory before shelling out to `gitnexus` or analyze/reindex commands."
---

# GitNexus CLI

## When to Use

- Indexing a repo for the first time
- Reindexing after large changes
- Checking if the index is stale or up to date
- Clearing and rebuilding the index
- Generating a wiki or AI context files

## Commands

```bash
# Index a repo
gitnexus analyze                        # Generic repo
gitnexus unity analyze --embeddings     # Unity project

# Check status
gitnexus list                           # List indexed repos

# Regenerate AI context (AGENTS.md, CLAUDE.md sections)
gitnexus ai-context

# Force full reindex
gitnexus analyze --force

# Generate wiki
gitnexus wiki
```

## When to Reindex

- After adding or deleting many files
- After a large merge or rebase
- When gitnexus tools return stale data
- Context resource says "Index is stale"

## Checklist

```
- [ ] cd into the repo root first
- [ ] Run gitnexus analyze (or unity analyze for Unity projects)
- [ ] Wait for completion — check for errors
- [ ] Verify with gitnexus list
- [ ] Re-run ai-context if AGENTS.md / CLAUDE.md need updating
```

## Flags

| Flag | Effect |
|------|--------|
| `--force` | Full reindex regardless of git state |
| `--embeddings` | Generate semantic embeddings (Unity) |
| `--drop-embeddings` | Drop + rebuild embeddings |
| `--skip-agents-md` | Skip AGENTS.md / CLAUDE.md update |
