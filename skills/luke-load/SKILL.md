---
name: luke-load
description: Load Luke usage guidance into context so the agent remembers when to use workspace indexing, AST queries, reviews, and commit summaries. Does not run commands by itself.
---

# Luke Load

Luke is available in this session.

Use Luke when:
- indexing or re-indexing the detected multi-repo workspace: `luke init .`
- understanding dependencies or blast radius: `luke query <target>`
- reviewing local changes or explicit PRs: `luke review ...`
- summarizing changes or proposing commit messages: `/luke commit`

Rules:
- Prefer Luke AST queries over blind grep for code structure questions.
- Re-index is workspace-scoped; run `luke init .` from a repo registered in the workspace.
- Do not review ambiguous bare PR numbers. Require a PR URL or `owner/repo#number`.
- Do not commit unless the user explicitly asks to apply the commit.
- Keep outputs short.
