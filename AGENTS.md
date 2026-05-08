<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **antigravity-gitnexus** (20298 symbols, 26452 relationships, 268 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/antigravity-gitnexus/context` | Codebase overview, check index freshness |
| `gitnexus://repo/antigravity-gitnexus/clusters` | All functional areas |
| `gitnexus://repo/antigravity-gitnexus/processes` | All execution flows |
| `gitnexus://repo/antigravity-gitnexus/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Use this global skill |
|------|-----------------------|
| Understand architecture / "How does X work?" | `gitnexus-exploring` |
| Blast radius / "What breaks if I change X?" | `gitnexus-impact-analysis` |
| Trace bugs / "Why is X failing?" | `gitnexus-debugging` |
| Rename / extract / split / refactor | `gitnexus-refactoring` |
| Tools, resources, schema reference | `gitnexus-guide` |
| Index, status, clean, wiki CLI commands | `gitnexus-cli` |

<!-- gitnexus:end -->
