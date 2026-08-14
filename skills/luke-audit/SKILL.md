---
name: luke-audit
description: Performs a read-only, file-by-file whole-workspace audit for security defects, correctness bugs, and code smells.
---

# Luke Audit

Use this skill when the user asks to audit a workspace, repository, module, or change set for security issues, bugs, performance problems, missing tests, or code smells.

## Boundary

- Read-only. Do not edit application files, install dependencies, change configuration, or auto-fix findings.
- Report only evidence-backed findings. If evidence is incomplete, label it as a risk or question.
- Audit the entire requested workspace unless the user explicitly limits scope.

## Workflow

1. Orient first:
   ```bash
   luke status
   ```
   Identify the workspace root, active task state, languages, generated/vendor directories, tests, and build configuration.

2. Use an already available Luke AST index when one exists. Run `luke query tree <file-or-symbol>` and `luke query impact <file-or-symbol>` only against that existing index to trace imports, callers, and blast radius. Do not run `luke workspace init` or `luke index`: both write state. If no usable index exists, record the limitation and use read-only file inspection. Ask for explicit permission before any indexing operation that writes state.

3. Inventory every relevant source and test file. Group files by language and domain (entrypoints, API/network, auth, persistence, parsing, filesystem, background jobs, UI, shared utilities, tests). Exclude generated output, dependencies, and binaries unless they are in scope or suspicious.

4. Inspect groups systematically, file by file. For each file, check:
   - security: authentication, authorization, validation, secrets, injection, path traversal, unsafe deserialization, SSRF, cryptography, logging/privacy, and dependency boundaries;
   - correctness: error handling, null/empty states, races, retries, timeouts, cleanup, resource lifetime, and unsafe assumptions;
   - quality: duplication, dead code, complexity, API misuse, performance hotspots, and maintainability smells;
   - tests: missing coverage for security boundaries, failures, edge cases, and regressions.

5. Delegate independent, read-only domain groups to subagents when available. Give each a disjoint file set and require the evidence format below. Do not delegate writers and do not allow concurrent file changes. Consolidate duplicate findings before reporting.

6. When an existing index is available, trace every candidate through callers and inputs with `luke query` before classifying it. Otherwise trace from source with read-only inspection and label unverified reachability as a risk or question. Do not report a theoretical issue as a confirmed defect without a reachable mechanism.

## Finding Format

For every finding, provide:

```text
<severity: critical|high|medium|low>  path/to/file:line-or-range
Issue: concise mechanism.
Impact: concrete consequence and reachability.
Fix: minimum safe remediation.
Evidence: relevant input, caller, or AST query result.
```

Use `risk` or `question` instead of a severity when reachability cannot be verified. Keep findings ordered by severity, then path.

## Final Report

```text
## Audit Scope
Files inspected: <count/list or grouped inventory>
Coverage gaps: <unreadable/generated/excluded files and why>

## Findings
<evidence-backed findings, or "No confirmed findings.">

## Residual Risks
<unverified concerns, unavailable checks, or "None known.">

## Verification
- luke status: <result>
- luke index/query: <result or limitation>
- delegated read-only coverage: <agents/files, if used>
```

Never claim the workspace is secure. State only the coverage completed and residual risk.
