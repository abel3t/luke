---
name: luke-review
description: Orchestrates a strict AST-aware review of local changes or PRs.
---

# Luke Review Coordinator

When this skill is activated, use the Luke CLI to inspect changed code before reviewing.

## Step 1: Execute the AST Diff Engine

Run the native Zig binary:
```
luke review
```
If the user provided a commit hash or PR number, pass it as an argument (e.g., `luke review HEAD~1..HEAD` or `luke review --pr 123 456`).

## Step 2: Parse the JSON Payload

The Zig engine outputs a JSON array to **stdout**. Each object contains:
- `file` — the changed file path
- `node` — the function or class name
- `type` — the AST node type
- `start_line` / `end_line` — exact line range in the file
- `agents_required` — list of specialized agent TypeNames to spawn

## Step 3: Review the Affected Nodes

For every object in the JSON array, inspect the exact file path and line range (`start_line` to `end_line`) plus the relevant git diff. Focus on the requested review dimensions from `agents_required` (for example bloat, edge cases, security, concurrency).

## Step 4: Synthesize the Report

Synthesize findings into a single report printed directly into chat. Do NOT create a Markdown Artifact file.

Format:
```
## Luke Review: <branch or commit>

### <file>

<node>:L<start>-<end>
  [bloat-hunter]  <finding or "Lean already. Ship.">
  [edge-case-hunter]  <finding or "No issues.">

---
net: -<N> lines possible. totals: <X>🔴 <Y>🟡 <Z>🔵
```

Do not soften findings. Preserve the exact tag format from each agent.

## Step 5: Be Direct

Do not soften findings. If no issue exists, say so briefly.
