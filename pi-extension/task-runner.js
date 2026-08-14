import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

export async function orchestrateTask({ target, cwd, signal, onProgress }) {
	if (!target || target.trim().length < 10) {
		throw new Error("Task too short. Be explicit.");
	}

	if (!existsSync(join(cwd, ".luke"))) {
		throw new Error("Not a registered workspace. Run 'luke workspace init' first.");
	}

	onProgress(`Starting task: ${target}`);

	// Kiểm tra xem đã index chưa bằng cách test thử luke query
	try {
		await execFileAsync("luke", ["query", "test_index_check"], { cwd });
	} catch (e) {
		if (e.message.includes("not found") || e.message.includes("no index")) {
			throw new Error("No index. Run 'luke index' first.");
		}
	}
	
	const prompt = `You are an automated task executor following a strict GSD-like process.
Target task: ${target}

Process:
1. PLAN: Read relevant files to understand the requirements and context. Output a clear plan.
2. EXECUTE: Make surgical changes using your edit/write tools. Do not over-engineer.
3. VERIFY: Run tests or verification commands to prove the change works.

Strict Rules:
- Stop & Ask: If unclear, don't assume. Stop.
- No Speculative Code: Implement ONLY what is requested.
- Surgical Edits: Do not reformat or refactor adjacent code. Clean up only your own orphans.
- Verifiable Steps: Verify (test) each step. Do not finish until tests pass.`;

	return new Promise((resolvePromise, reject) => {
		const child = spawn(
			"pi",
			["--no-session", "--tools", "read,bash,grep,find,ls,write,edit", prompt],
			{ cwd, stdio: ["ignore", "pipe", "pipe"] }
		);

		let stdout = "";
		let stderr = "";
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		
		child.stdout.on("data", (chunk) => {
			stdout += chunk;
		});
		
		child.stderr.on("data", (chunk) => {
			stderr += chunk;
		});

		const abort = () => child.kill("SIGTERM");
		if (signal) {
			signal.addEventListener("abort", abort, { once: true });
		}

		child.on("error", (err) => reject(err));
		
		child.on("close", (code) => {
			if (signal) {
				signal.removeEventListener("abort", abort);
			}
			if (code !== 0) {
				reject(new Error(stderr || `Task failed with exit code ${code}`));
			} else {
				resolvePromise({ output: stdout });
			}
		});
	});
}
