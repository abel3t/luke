---
name: luke-sweep
description: Acts as LUKE's memory consolidator. Compresses task data into Caveman memory.
---

# luke-sweep

This skill defines the process of "Garbage Collection & Memory Consolidation" (Sweep/Sleep) for the LUKE system.

## Trigger
Execute this skill when the user runs the slash command `/luke-sweep` or asks to clean up completed tasks.

## Workflow

1. **Read Completed Tasks:**
   Check `.luke/tasks/` for folders where `state.zon` has `status = .Done` or `.Cancelled`.

2. **Prepare Hard Data (Zig CLI):**
   Run `luke sweep prepare <task_id>`. This outputs `start_commit`, `end_commit`, and the exact commit hashes for all affected repos.

3. **Read Soft Data (Notes & Spec):**
   Read `SPEC.md`, `NOTES.md`, and `REVIEW.md` inside `.luke/tasks/<task_id>/`.

4. **Consolidate Memory in BRAIN.md:**
   Read the existing `BRAIN.md` in the workspace root. Combine its existing knowledge with the Hard and Soft data of the new task.
   **RULES FOR COMPRESSION:**
   - Write in **LUKE** style. Terse, minimum fragments, no filler.
   - Overwrite obsolete architectural facts. (e.g., if the new task dropped JWT for OAuth, delete the old JWT fact).
   - Ensure the total size of `BRAIN.md` remains small (O(1) capacity). Do NOT just append a log.
   - Use the `replace_file_content` or `write_to_file` tool to save the updated `BRAIN.md`.

5. **Finalize (Zig CLI):**
   Call `luke sweep finalize <task_id>`.
   - The Zig CLI will permanently `rm -rf` the task folder, as its knowledge is now safely stored in `BRAIN.md`.

Repeat until `.luke/tasks/` only contains `Pending` or `InProgress` tasks.
