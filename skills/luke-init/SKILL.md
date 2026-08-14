---
name: luke-init
description: Initialize a LUKE workspace in the global registry and build the AST index.
---

# Luke Init

Register a directory into the global LUKE workspace registry and build the AST index.

## Usage

When you are told "Not a registered LUKE workspace" or need to initialize a project:

1. Register the workspace:
```bash
luke workspace init <name>
```

2. Build the AST index:
```bash
luke index
```

## Rules
- You MUST run `luke workspace init <name>` using bash. Provide a short slug-like name for the project.
- You MUST run `luke index` right after registering, otherwise the AST guard will block other tools.
