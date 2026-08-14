---
name: luke-index
description: Rebuild the Luke AST knowledge graph for the local workspace.
---

# Luke Index

Rebuild the Luke AST knowledge graph for the current workspace.

## Usage

Run from the root of your repository:

```bash
luke index
```

Luke operates using a global registry. Workspaces are registered in `~/.luke/workspaces/`.

## Rules

- Use this when the user asks to index, re-index, rescan, refresh Luke, or rebuild the knowledge graph.
- Indexing reads the global registry to find the workspace context.
- If the workspace is not registered, you must run `luke workspace init <name>` before indexing.
- Keep output short: report parsed file count and saved index path if available.
