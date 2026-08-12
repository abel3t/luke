---
name: query
description: "Query the Luke AST knowledge graph to understand the dependencies and blast radius of any file, function, or class."
---

# `luke:query` Skill

You have access to a powerful internal AST knowledge graph built using the `luke` CLI engine.

Whenever you are asked to analyze code, understand dependencies, or determine the "blast radius" of a potential refactor, you MUST use `luke` to query the knowledge graph instead of just trying to grep through the codebase blindly.

## Setup
If the knowledge graph is not built yet (or is out of date), you must first initialize it:
```bash
luke init .
```
This command parses all `.ts`, `.tsx`, and `.go` files in the workspace and builds a fast, local `.zon` knowledge graph in `~/.luke/<workspace>/longterm.zon`.

## Usage
To search the graph for a specific file, class, struct, or function name, run:
```bash
luke query <target_name>
```

For example, to find all references to `WorkspaceWalker`:
```bash
luke query WorkspaceWalker
```

### Understanding the Output
The output will show:
- `[NODE]`: The specific symbol (Function, Class, Struct, File) you queried and where it lives.
- `[USES]`: The dependencies that this node relies on (e.g. what it imports or calls).
- `[USED_BY]`: The dependents that rely on this node (e.g. who imports or calls it).

Use this structural information to inform your analysis or code modifications with perfect accuracy.
