---
name: luke-agy-audit
description: Use Luke AST data with Antigravity/Agy for a disciplined whole-project audit.
---

# Luke + Agy Project Audit

Use this skill only in Agy/Antigravity. Agy does not load Luke's Pi extension runner, so execute Luke CLI commands directly.

## Setup

From the repository root:

```bash
luke init .
luke audit
```

If `audit` says no index exists, run `luke init .` and retry. Treat audit JSON as **structural candidates**, not confirmed defects.

## Audit workflow

1. Read the structural candidates from `luke audit`.
2. Enumerate supported source files (`.ts`, `.tsx`, `.go`) and inspect them in bounded file/symbol batches.
3. Use `luke query <symbol-or-file>` before expanding related code; inspect callers, tests, configuration, schemas, and migrations when relevant.
4. Review for:
   - correctness and edge cases;
   - security, authorization, validation, secrets, and injection;
   - data integrity, transactions, migrations, concurrency, and retries;
   - performance, N+1 queries, memory/resource leaks;
   - design boundaries, unnecessary complexity, DRY candidates, and test gaps.
5. Validate a candidate before reporting it. Do not call a symbol dead code merely because it has no visible references: Luke does not yet provide reliable import/call/use edges.
6. Run available project checks. Report failed or unavailable checks explicitly.

## Reporting

Report only actionable findings by default:

```text
severity  path:line
Failure mechanism. Concrete fix.
```

Then include:

```text
Audit scope: <files/symbols actually inspected>
Verification: passed / failed / unavailable checks
Limitations: no full-line coverage or reliable reachability/dead-code proof yet
```

Never claim every project line was audited unless an external orchestrator has recorded that coverage.
