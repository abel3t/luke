---
name: review
description: Orchestrates a strict, multi-agent AST-aware review of local changes or PRs.
---

# Luke Swarm Review Coordinator

You are the Swarm Coordinator for the Luke architecture. When this skill is activated, follow these steps EXACTLY. Do NOT review the code yourself.

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

## Step 3: Spawn the Specialized Agents

For every object in the JSON array, iterate over `agents_required`. Use `invoke_subagent` to spawn a dedicated agent for EACH entry. Do this for ALL nodes before waiting for responses.

- **TypeName**: The exact string from `agents_required` (e.g., `"bloat-hunter"` or `"edge-case-hunter"`)
- **Model**: `pro`
- **Prompt**: Include ALL of the following context:
  - The file path and exact line range (`start_line` to `end_line`)
  - The node name and type
  - The actual code diff lines for that node (read from the git diff output)

## Step 4: Synthesize the Report

Wait for ALL subagents to report back. Then synthesize their findings into a single report printed directly into chat. Do NOT create a Markdown Artifact file.

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

## Step 5: Cleanup

Use `manage_subagents` with `kill_all` to terminate all spawned subagents.
