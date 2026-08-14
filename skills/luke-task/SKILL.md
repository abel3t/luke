---
name: luke-task
description: Orchestrates an automated task utilizing a zero-context Subagent and the LUKE Zig Task Engine.
---

# luke-task

Enforces LUKE's Lazy Delegation and strictly Deterministic Single-Task architecture via the Zig Task Engine.

## Rules
- LUKE is SINGLE TASK. Only one task can be active in a workspace at a time (enforced by the Git Worktree structure).
- LUKE NEVER writes code directly on the main thread.
- If a task is active, reject new tasks until the current one is `approve`d or `cancel`led.

## The State Machine (PI-SDK Extension)

LUKE (the AI) must interact with the PI-Agent Extension Tool to manage the task lifecycle. Do NOT manually create folders. Use the `luke_task_engine` tool.

1. **Create:** `luke_task_engine({ subcommand: 'create', taskId: 'T-01' })`
   - Zig creates a Git Worktree at `.luke/worktrees/T-01`.
   - Zig records `start_commit` (Git HEAD).
   - State: `Pending`.

2. **Claim:** `luke_task_engine({ subcommand: 'claim', taskId: 'T-01' })`
   - The subagent claims the task to start working.
   - State: `InProgress`.

3. **Submit:** `luke_task_engine({ subcommand: 'submit', taskId: 'T-01' })`
   - The subagent finishes coding and submits.
   - Zig automatically runs AST validation (`luke index`). Fails if syntax is broken.
   - State: `ReviewPending`.

4. **Approve / Reject:**
   - `luke_task_engine({ subcommand: 'approve', taskId: 'T-01' })` -> State: `Done`. Subagent must merge branch manually or PI-SDK handles it. Zig removes worktree.
   - `luke_task_engine({ subcommand: 'reject', taskId: 'T-01' })` -> State: `InProgress`. Subagent must fix.
   - `luke_task_engine({ subcommand: 'cancel', taskId: 'T-01' })` -> State: `Cancelled`. Zig forces removal of the worktree.

