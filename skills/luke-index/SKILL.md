---
name: luke-index
description: Rebuild the Luke AST knowledge graph for the detected multi-repo workspace.
---

# Luke Index

Rebuild the Luke AST knowledge graph for the detected workspace.

## Usage

Run from any repo registered in the workspace:

```bash
luke init .
```

Luke detects the workspace from the current directory and indexes all folders registered in that workspace.

## Rules

- Use this when the user asks to index, re-index, rescan, refresh Luke, or rebuild the knowledge graph.
- Re-index is workspace-scoped, not single-repo scoped.
- Do not pass a guessed workspace name as a path.
- If Luke cannot detect a workspace, stop and ask the user to create/add the workspace first.
- Keep output short: report parsed file count and saved index path if available.
