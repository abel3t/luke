---
name: luke-index
description: Rebuild the Luke AST knowledge graph for the local workspace.
---

# Luke Index

Rebuild the Luke AST knowledge graph for the current workspace.

## Usage

Run from the root of your repository:

```bash
luke workspace init .
luke index .
```

Luke operates purely on a local-first principle. One `.luke` directory per repository. It does not use any global registry anymore.

## Rules

- Use this when the user asks to index, re-index, rescan, refresh Luke, or rebuild the knowledge graph.
- Indexing is completely local to the `.luke` boundary.
- If `.luke` is missing, you must run `luke workspace init .` before indexing.
- Keep output short: report parsed file count and saved index path if available.
