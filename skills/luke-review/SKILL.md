---
name: luke-review
description: Runs a manifest-backed AST-aware review of local changes or an explicit PR.
---

# Luke Review

The automated extension command is the user-facing entrypoint:

```text
/luke review <range-or-explicit-PR>
```

It resolves an explicit PR to a detached PR-head worktree, runs isolated read-only workers one unit at a time, submits structured evidence, runs `git diff --check`, and finalizes only after all units succeed. Use `/luke-review <target>` as its direct alias. Do not use `/skill:luke-review` as an orchestration entrypoint.

For manual or non-Pi use, start a review with exactly one Luke command:

```bash
luke review start
```

For a range, append it (for example `luke review start HEAD~1..HEAD`). For a PR, an explicit repository is required:

```bash
luke review start --pr https://github.com/owner/repo/pull/123
luke review start --pr owner/repo#123
```

Never accept a bare PR number. Do not print or request the complete chunk plan: start emits only a compact run and coverage summary.

`review next <run-id>` and `review submit <run-id> <chunk-id> <result.json>` are internal lifecycle commands. Use them only when an automated worker loop is available. A result JSON must acknowledge assigned ranges and give each finding a line, severity, mechanism, and fix. `review finalize <run-id>` is the only command that may establish completed coverage.

Until finalization, say **planned coverage**, never “reviewed coverage.” Do not fabricate subagents: `review_lenses` are dimensions applied by the current reviewer.

## Report

Report findings by severity and location. Omit clean lens-by-lens chatter unless asked for verbose output. Always separately report verification results, including commands that failed or could not run; never translate a failed check into “No issues.”

Use this concise shape:

```text
## Luke Review: <target>

warning  path:line
Mechanism and concrete fix.

Verification
✓ <check>
✗ <failed/unavailable check>: <reason>

Coverage: planned or reviewed <n>/<n> changed lines.
```
