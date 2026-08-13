import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import { orchestrateReview } from "./review-runner.js";

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

export default function lukeExtension(pi) {
	injectLukePath();

	pi.registerCommand("luke", {
		description:
			"Luke commands: help, load, index, query <target>, audit, review [range|--pr ...], commit",
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
				const result = await runLuke(["audit"], ctx?.cwd || process.cwd());
				pi.sendUserMessage(result.stdout || result.stderr, {
					deliverAs: "followUp",
				});
				return;
			}
			if (command === "review") return runAutomatedReview(pi, forwarded, ctx);
			if (command === "commit")
				return sendSkill(pi, "luke-commit", forwarded, ctx);

			ctx?.ui?.notify?.(
				"Unknown Luke command. Use /luke help, /luke load, /luke index, /luke query <target>, /luke audit, /luke review, or /luke commit.",
				"warning",
			);
		},
	});

	for (const [name, skill] of [
		["luke-help", "luke-help"],
		["luke-load", "luke-load"],
		["luke-index", "luke-index"],
		["luke-query", "luke-query"],
		["luke-review", "luke-review"],
		["luke-commit", "luke-commit"],
	]) {
		pi.registerCommand(name, {
			description:
				name === "luke-review"
					? "Run automated manifest-backed Luke review"
					: `Run /skill:${skill}`,
			handler: (args, ctx) =>
				name === "luke-review"
					? runAutomatedReview(pi, args, ctx)
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
}
