---
name: luke-review
description: Orchestrates a strict AST-aware review of local changes or PRs.
---

# Luke Review Coordinator

When this skill is activated, use the Luke CLI to inspect changed code before reviewing.

## Step 1: Execute the AST Diff Engine

Create a persistent review manifest:
```bash
luke review start
```

The command writes a manifest under `~/.luke/reviews/` and returns a run id. Use:
```bash
luke review status <run-id>
luke review complete <run-id> <chunk-id>
luke review finalize <run-id>
```

`finalize` must fail until every assigned chunk is complete.
If the user provided a commit hash or range, pass it as an argument (e.g., `luke review HEAD~1..HEAD`).

For PR review, require an explicit repository or PR link. Valid forms:
```bash
luke review --pr https://github.com/owner/repo/pull/123
luke review --pr owner/repo#123
luke review --pr owner/repo 123
luke review --pr -R owner/repo 123
```

Do NOT review a bare PR number like `luke review --pr 123`; in multi-repo workspaces it is ambiguous. If the user provides only a PR number or otherwise lacks enough data, stop and ask for a GitHub PR link or `owner/repo#number`.

## Step 2: Parse the JSON Payload

The Zig engine outputs an object with deterministic `coverage` and `chunks` fields. Each chunk contains:
- `file` — the changed file path
- `node` — the smallest enclosing AST symbol, or a file fallback
- `type` — the AST node type
- `start_line` / `end_line` — the source context range
- `changed_ranges` — every changed line range assigned to this chunk
- `review_lenses` — review dimensions to apply

Do not claim the review is complete unless `uncovered_changed_lines` and failed chunks are zero.

## Step 3: Review the Assigned Chunks

For every chunk, inspect its exact source context plus its assigned diff ranges. Apply every requested `review_lens` yourself; Pi does not spawn Luke subagents. Do not skip a chunk or expand the scope silently.

## Step 4: Synthesize the Report

Synthesize findings into a single report printed directly into chat. Do NOT create a Markdown Artifact file.

Format:
```
## Luke Review: <branch or commit>

### <file>

<node>:L<start>-<end>
  [bloat-hunter]  <finding or "No issues.">
  [edge-case-hunter]  <finding or "No issues.">

---
net: -<N> lines possible. totals: <X>🔴 <Y>🟡 <Z>🔵
```

Preserve the exact lens tag format. Every finding needs a concrete line, failure mechanism, and fix.

## Step 5: Be Direct

Do not soften findings. If no issue exists, say so briefly.
