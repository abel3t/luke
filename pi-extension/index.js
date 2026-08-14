import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync as readFileSyncNode } from "node:fs";
import { dirname, resolve, join } from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import { orchestrateReview } from "./review-runner.js";
import { orchestrateTask } from "./task-runner.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(__dirname, "..");
const lukeBin = resolve(packageRoot, "bin", "luke");
const lukeBinDir = dirname(lukeBin);

function injectLukePath() {
	const parts = String(process.env.PATH || "").split(":");
	if (!parts.includes(lukeBinDir)) {
		process.env.PATH = `${lukeBinDir}:${process.env.PATH || ""}`;
	}
}

function splitArgs(text) {
	return (
		String(text || "")
			.trim()
			.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)
			?.map((part) => part.replace(/^(["'])(.*)\1$/, "$2")) || []
	);
}


function getGlobalWorkspaceSlug(cwd) {
	const workspacesDir = join(os.homedir(), ".luke", "workspaces");
	if (!existsSync(workspacesDir)) return null;
	const entries = readdirSync(workspacesDir, { withFileTypes: true });
	for (const entry of entries) {
		if (entry.isDirectory()) {
			const wsJsonPath = join(workspacesDir, entry.name, "workspace.json");
			if (existsSync(wsJsonPath)) {
				try {
					const ws = JSON.parse(readFileSyncNode(wsJsonPath, "utf8"));
					if (ws.folders && ws.folders.some(f => cwd.startsWith(f.path))) {
						return ws.slug;
					}
				} catch (e) {}
			}
		}
	}
	return null;
}

function checkWorkspace(ctx) {
	const cwd = ctx?.cwd || process.cwd();
	const slug = getGlobalWorkspaceSlug(cwd);
	if (!slug) {
		const msg = "Not a registered LUKE workspace. Run 'luke workspace init' in the global registry.";
		ctx?.ui?.notify?.(msg, "error");
		throw new Error(msg);
	}
	return slug;
}

function runLuke(args, cwd, signal) {
	return new Promise((resolvePromise) => {
		if (!existsSync(lukeBin)) {
			resolvePromise({
				exitCode: 127,
				stdout: "",
				stderr: `Luke binary not found: ${lukeBin}`,
			});
			return;
		}

		const child = spawn(lukeBin, args, {
			cwd,
			env: { ...process.env, PATH: `${lukeBinDir}:${process.env.PATH || ""}` },
			stdio: ["ignore", "pipe", "pipe"],
		});

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
		signal?.addEventListener?.("abort", abort, { once: true });

		child.on("error", (error) => {
			signal?.removeEventListener?.("abort", abort);
			resolvePromise({ exitCode: 1, stdout, stderr: stderr || error.message });
		});

		child.on("close", (code) => {
			signal?.removeEventListener?.("abort", abort);
			resolvePromise({ exitCode: code ?? 0, stdout, stderr });
		});
	});
}

async function runAutomatedReview(pi, args, ctx) {
	const target = String(args || "").trim();
	if (!target) {
		ctx?.ui?.notify?.(
			"Provide a diff range or an explicit GitHub PR URL.",
			"warning",
		);
		return;
	}
	try {
		checkWorkspace(ctx);
		const result = await orchestrateReview({
			lukeBin,
			target,
			cwd: ctx?.cwd || process.cwd(),
			onProgress: (message) => ctx?.ui?.notify?.(`Luke: ${message}`, "info"),
		});
		const findings = result.findings;
		const lines = [
			`Luke review complete: ${result.coverage.eligible_changed_lines}/${result.coverage.eligible_changed_lines} changed lines reviewed.`,
			`Verification ${result.verification.status}: ${result.verification.detail}`,
			findings.length ? `${findings.length} finding(s):` : "No findings.",
			...findings.map(
				(f) =>
					`${f.severity} ${f.file}:${f.line} — ${f.mechanism} Fix: ${f.fix}`,
			),
		];
		const report = lines.join("\n");
		ctx?.ui?.notify?.(
			lines.slice(0, 2).join(" "),
			findings.length ? "warning" : "info",
		);
		pi.sendUserMessage(report, { deliverAs: "followUp" });
		return report;
	} catch (error) {
		const message = `Luke review failed: ${error instanceof Error ? error.message : String(error)}`;
		ctx?.ui?.notify?.(message, "error");
		throw new Error(message);
	}
}

async function runAutomatedTask(pi, args, ctx) {
	const target = String(args || "").trim();
	if (!target) {
		ctx?.ui?.notify?.(
			"Provide a task description.",
			"warning",
		);
		return;
	}
	try {
		checkWorkspace(ctx);
		const result = await orchestrateTask({
			target,
			cwd: ctx?.cwd || process.cwd(),
			onProgress: (message) => ctx?.ui?.notify?.(`Luke Task: ${message}`, "info"),
		});
		const report = `Luke task complete.\n\n${result.output}`;
		ctx?.ui?.notify?.("Task completed", "info");
		pi.sendUserMessage(report, { deliverAs: "followUp" });
		return report;
	} catch (error) {
		const message = `Luke task failed: ${error instanceof Error ? error.message : String(error)}`;
		ctx?.ui?.notify?.(message, "error");
		throw new Error(message);
	}
}

function sendSkill(pi, skillName, args, ctx) {
	const suffix = String(args || "").trim();
	const message = suffix
		? `/skill:${skillName} ${suffix}`
		: `/skill:${skillName}`;

	if (ctx?.isIdle?.() === false) {
		pi.sendUserMessage(message, { deliverAs: "followUp" });
		ctx?.ui?.notify?.(`${message} queued as follow-up.`, "info");
		return;
	}

	pi.sendUserMessage(message);
}


export default function (pi) {
	// Lifecycle events
	pi.on("session_start", async (_event, ctx) => {
		ctx.ui?.notify?.("LUKE Extension activated", "info");
	});

	pi.on("tool_call", async (event, ctx) => {
		const isBash = event.toolName === "bash" || event.toolName === "run_command";
		if (isBash) {
			const cmd = event.input?.command || event.input?.CommandLine || "";
			if (cmd.includes("luke ") && !cmd.includes("luke workspace init")) {
				const cwd = ctx?.cwd || process.cwd();
				const slug = getGlobalWorkspaceSlug(cwd);
				if (!slug) {
					return {
						block: true,
						reason: "Not a registered LUKE workspace. You MUST call the 'luke-init' skill first.",
					};
				}
				if (!cmd.includes("luke index") && !cmd.includes("luke init")) {
					const astPath = join(os.homedir(), ".luke", "workspaces", slug, "ast.zon");
					if (!existsSync(astPath)) {
						return {
							block: true,
							reason: `LUKE workspace '${slug}' is registered but AST index is missing. You MUST call the 'luke-init' skill first.`,
						};
					}
				}
			}
			if (cmd.includes("luke task create")) {
				const ok = await ctx?.ui?.confirm?.("LUKE Task Engine", "AI is attempting to create a task via bash. Allow?");
				if (!ok) {
					return { block: true, reason: "Blocked by user. Do NOT create tasks without approval." };
				}
			}
			if (cmd.includes("luke task approve")) {
				const ok = await ctx?.ui?.confirm?.("LUKE Task Engine", "AI is attempting to APPROVE a task via bash. Allow?");
				if (!ok) {
					return { block: true, reason: "Blocked by user. Task approval aborted." };
				}
			}
		}
		
		if (event.toolName === "invoke_subagent") {
			const ok = await ctx?.ui?.confirm?.("LUKE Delegation", "LUKE is spawning a subagent. Did you already approve the SPEC.md plan?");
			if (!ok) {
				return { block: true, reason: "Blocked by user. You MUST get the plan approved via ask_question before spawning subagents." };
			}
		}

		const isEditTool = event.toolName === "write_to_file" || event.toolName === "replace_file_content" || event.toolName === "edit_file";
		if (isEditTool) {
			const targetPath = event.input?.TargetFile || event.input?.path || "";
			if (targetPath && !targetPath.includes(".luke/tasks/")) {
				return { block: true, reason: "FATAL: Code edits outside of a Task Worktree are strictly forbidden by LUKE Engine. You MUST use luke_task_engine to create a task first." };
			}
		}
	});
	injectLukePath();

	pi.registerCommand("luke", {
		description:
			"Luke commands: help, load, index, query <target>, audit, review [range|--pr ...], task <desc>, commit",
		handler: async (args, ctx) => {
			const [command, ...rest] = splitArgs(args);
			const forwarded = rest.join(" ");

			if (!command || command === "help")
				return sendSkill(pi, "luke-help", forwarded, ctx);
			if (command === "load") return sendSkill(pi, "luke-load", forwarded, ctx);
			if (command === "index" || command === "init")
				return sendSkill(pi, "luke-index", forwarded, ctx);
			if (command === "query")
				return sendSkill(pi, "luke-query", forwarded, ctx);
			if (command === "audit") {
				checkWorkspace(ctx);
				const result = await runLuke(["audit"], ctx?.cwd || process.cwd());
				pi.sendUserMessage(result.stdout || result.stderr, {
					deliverAs: "followUp",
				});
				return;
			}
			if (command === "review") return runAutomatedReview(pi, forwarded, ctx);
			if (command === "task") return runAutomatedTask(pi, forwarded, ctx);
			if (command === "commit")
				return sendSkill(pi, "luke-commit", forwarded, ctx);

			ctx?.ui?.notify?.(
				"Unknown Luke command. Use /luke help, /luke load, /luke index, /luke query <target>, /luke audit, /luke review, /luke task <desc>, or /luke commit.",
				"warning",
			);
		},
	});

	for (const [name, skill] of [
		["luke-help", "luke-help"],
		["luke-init", "luke-init"],
		["luke-load", "luke-load"],
		["luke-index", "luke-index"],
		["luke-query", "luke-query"],
		["luke-review", "luke-review"],
		["luke-task", "luke-task"],
		["luke-commit", "luke-commit"],
	]) {
		pi.registerCommand(name, {
			description:
				name === "luke-review"
					? "Run automated manifest-backed Luke review"
					: name === "luke-task"
						? "Run automated Luke task with GSD process"
						: `Run /skill:${skill}`,
			handler: (args, ctx) =>
				name === "luke-review"
					? runAutomatedReview(pi, args, ctx)
					: name === "luke-task"
						? runAutomatedTask(pi, args, ctx)
						: sendSkill(pi, skill, args, ctx),
		});
	}

	pi.registerTool({
		name: "luke",
		label: "Luke",
		description:
			"Run the Luke AST knowledge-graph CLI for code dependency queries and reviews.",
		promptSnippet: "Run Luke AST knowledge-graph commands: init, query, review",
		promptGuidelines: [
			"Use the luke tool for AST-aware dependency/blast-radius queries instead of blind grep when analyzing code structure.",
			"Use the luke tool with review when the user asks for a Luke review of local changes or a range.",
		],
		parameters: Type.Object({
			args: Type.Array(Type.String(), {
				description:
					"Arguments passed to the luke CLI, e.g. ['query', 'MyFunction'] or ['review'].",
			}),
			cwd: Type.Optional(
				Type.String({
					description: "Working directory. Defaults to the current project.",
				}),
			),
		}),
		async execute(_toolCallId, params, signal) {
			const cwd = params.cwd || process.cwd();
			const slug = getGlobalWorkspaceSlug(cwd);
			if (!slug) return { content: [{ type: "text", text: "Not a registered LUKE workspace. You MUST call the 'luke-init' skill first." }] };
			const result = await runLuke(params.args || [], cwd, signal);
			const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
			return {
				content: [
					{
						type: "text",
						text: output || `luke exited with code ${result.exitCode}`,
					},
				],
				details: result,
			};
		},
	});

	pi.registerTool({
		name: "luke_task_engine",
		label: "LUKE Task Engine",
		description: "Interface to the LUKE Zig Task Engine for managing task lifecycles (Git Worktrees). Use subcommand 'create' to start a new task. The extension will automatically prompt the user for confirmation.",
		promptGuidelines: [
			"Never create tasks implicitly.",
			"When creating a task, use subcommand='create'. For other lifecycle events, use claim, submit, approve, reject, or cancel.",
		],
		parameters: Type.Object({
			subcommand: Type.Union([
				Type.Literal("create"),
				Type.Literal("claim"),
				Type.Literal("submit"),
				Type.Literal("approve"),
				Type.Literal("reject"),
				Type.Literal("cancel"),
			], { description: "The task lifecycle event to trigger." }),
			taskId: Type.String({ description: "The unique Task ID (e.g., T-01)." }),
			specPath: Type.Optional(Type.String({ description: "Path to the SPEC.md file. Only used for 'create'." })),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			const cwd = ctx?.cwd || process.cwd();
			const slug = getGlobalWorkspaceSlug(cwd);
			if (!slug) return { content: [{ type: "text", text: "Not a registered LUKE workspace. You MUST call the 'luke-init' skill first." }] };
			if (params.subcommand === "create") {
				const ok = await ctx?.ui?.confirm?.("LUKE Task Engine", `AI is requesting to physically create the Git Worktree for task ${params.taskId}. Allow?`);
				if (!ok) {
					return { content: [{ type: "text", text: "Task creation aborted by user." }] };
				}
			}
			if (params.subcommand === "approve") {
				const ok = await ctx?.ui?.confirm?.("LUKE Task Engine", `Are you sure you want to APPROVE task ${params.taskId}? This will merge the code and garbage collect the worktree.`);
				if (!ok) {
					return { content: [{ type: "text", text: "Task approval aborted by user." }] };
				}
			}
			const args = ["task", params.subcommand, params.taskId];
			if (params.subcommand === "create" && params.specPath) {
				args.push("--spec", params.specPath);
			}
			const result = await runLuke(args, cwd, signal);
			const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
			return {
				content: [{ type: "text", text: output || `luke exited with code ${result.exitCode}` }],
				details: result,
			};
		},
	});
}
