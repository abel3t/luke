# LUKE

LUKE is a highly-efficient, lazy, vectorless AST reasoning engine for your workspace.
It parses `.ts`, `.tsx`, `.js`, `.jsx`, and `.go` files into a compact, deterministic `.zon` file.

## Philosophy

- **Simplicity First**: 1 workspace = 1 folder.
- **Deterministic**: Everything lives in `.luke/ast.zon`. No external DBs, no vector stores, no heavy C++ extensions.
- **Fail-Fast**: If you don't run `luke index`, it won't magically scan. Explicit is better than implicit.
- **Agentic**: Designed to give AI agents exact blast radius (`query impact`) and tree structures (`query tree`), rather than semantic search fluff.

## Usage

### 1. Initialize & Index
In your repository root:
```bash
luke workspace init .
luke index .
```
This parses all supported files and dumps a structured graph into `.luke/ast.zon`.

### 2. Query the Graph

**View Structure (TOC / Dependencies):**
```bash
luke query tree <filename_or_node_id>
```
Shows everything a file contains (functions, classes), everything it calls, and everything it imports.

**View Blast Radius (Impact):**
```bash
luke query impact <function_name_or_file>
```
Shows every file that calls the given function, or imports the given file.

### 3. Audit
```bash
luke audit
```
Detects large symbols (design risk) and identically named symbols (DRY risk) using the deterministic `.zon` graph.

## Developer

To build LUKE from source:
```bash
npm run build
```
