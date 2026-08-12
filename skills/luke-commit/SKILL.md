---
name: luke-commit
description: Summarize current git changes and propose a commit message. Only commit when the user explicitly asks to apply the commit.
---

# Luke Commit

Summarize the current code changes and propose a commit message. Do NOT commit by default.

## Rules

- Inspect changes:
  ```bash
  git status --short
  git diff --stat
  git diff
  ```
- If multiple git repos have changes, summarize by repo.
- If there are no changes, say so and stop.
- If untracked files exist, inspect names/content before including them in the summary. Ignore secrets, build outputs, caches, or unrelated files.
- Produce a concise human commit message:
  - imperative mood
  - no trailing period

## Default Output

Unless the user explicitly asks to commit, output only:

```text
Summary: <one short line>
Message: <commit subject>
```

## Committing

Only commit when the user explicitly asks to commit, e.g. `/luke commit --apply`, `commit it`, or `commit these changes`.

Before committing:
- Stage only relevant files.
- If multiple repos have changes, stop and ask which repo(s) to commit unless the user explicitly said all repos.
- Commit with plain `git commit -m "..."` only.

After committing, output only:

```text
Committed <hash>: <subject>
```
