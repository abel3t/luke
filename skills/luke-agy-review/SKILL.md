---
name: luke-agy-review
description: Use Luke's manifest lifecycle from Antigravity/Agy for an evidence-backed PR or diff review.
---

# Luke + Agy Review

Use this skill only in Agy/Antigravity. Agy does not run Luke's Pi extension, so Agy must drive the CLI lifecycle itself.

## Start

For local changes/range:

```bash
luke review start HEAD~1..HEAD
```

For a PR, require an explicit repository identity. Never use a bare PR number:

```bash
luke review start --pr https://github.com/owner/repo/pull/123
luke review start --pr owner/repo#123
```

Read the compact JSON response and keep its `run_id`. It reports **planned** coverage only.

## Process every claimed unit

Repeat until `luke review next <run-id>` reports no pending chunks:

```bash
luke review next <run-id>
```

That atomically claims one unit. Review exactly its file, source range, changed ranges, and `review_lenses`. Pi-style lens names are review dimensions, not separate Agy agents.

Write a result file, for example `/tmp/luke-result.json`:

```json
{
  "acknowledged_ranges": [{"start": 10, "end": 15}],
  "findings": [
    {
      "line": 12,
      "severity": "warning",
      "mechanism": "Concrete failure mechanism",
      "fix": "Concrete fix"
    }
  ]
}
```

Every assigned range must be acknowledged verbatim. Every finding line must be inside an assigned changed range. For a clean unit, use an empty `findings` array.

Submit:

```bash
luke review submit <run-id> <chunk-id> /tmp/luke-result.json
```

If review execution fails twice, do not pretend it passed:

```bash
luke review block <run-id> <chunk-id>
```

## Finalize and report

Run:

```bash
luke review status <run-id>
luke review finalize <run-id>
```

Only after successful finalization may you say all assigned changed lines were reviewed. If any unit is pending, claimed, or blocked, say coverage is incomplete and retain the manifest.

Include verification separately. Failed/unavailable tests, lint, typecheck, migration checks, or `git diff --check` are never “No issues.”
