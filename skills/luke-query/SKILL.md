---
name: luke-query
description: "Query the Luke AST knowledge graph to understand the dependencies and blast radius of any file, function, or class."
---

# `luke-query` Skill

You have access to a powerful internal AST knowledge graph built using the `luke` CLI engine.

Whenever you are asked to analyze code, understand dependencies, or determine the "blast radius" of a potential refactor, you MUST use `luke` to query the knowledge graph instead of just trying to grep through the codebase blindly.

## Setup
If the knowledge graph is not built yet (or is out of date), you must first initialize it in the current repository:
```bash
luke workspace init .
luke index .
```
This command parses all `.ts`, `.tsx`, `.js`, `.jsx` and `.go` files in the workspace and builds a fast, local `.zon` knowledge graph in `<repo>/.luke/ast.zon`.

## Usage
The engine operates on a tree-based, vectorless structural graph. You can query the hierarchy (Tree) or the blast radius (Impact).

### 1. View Structure & Dependencies
To see what a file or function contains, calls, and imports, use the `tree` command:
```bash
luke query tree <target_name>
```

Example:
```bash
luke query tree my-file.ts
```
Output shows `[CONTAINS]`, `[CALLS]`, and `[IMPORTS]` edges going OUT of the target node.

### 2. Determine Blast Radius
To see who depends on a specific file or function (who calls it or imports it), use the `impact` command:
```bash
luke query impact <target_name>
```

Example:
```bash
luke query impact doThing
```
Output shows `[CALLED BY]` and `[IMPORTED BY]` edges coming INTO the target node.

Use this structural information to inform your analysis or code modifications with perfect accuracy.
