import { execFile, spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve as resolvePath } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const MAX_CONCURRENCY = 2;

async function command(commandName, args, cwd, timeout = 120_000) {
	try {
		const { stdout, stderr } = await execFileAsync(commandName, args, {
			cwd,
			timeout,
			maxBuffer: 2 * 1024 * 1024,
		});
		return { stdout, stderr };
	} catch (error) {
		error.detail = [error.stderr, error.stdout, error.message]
			.filter(Boolean)
			.join("\n")
			.trim();
		throw error;
	}
}

async function runLuke(lukeBin, args, cwd) {
	return command(lukeBin, args, cwd, 120_000);
}

function parseJson(text) {
	const trimmed = text.trim();
	try {
		return JSON.parse(trimmed);
	} catch {}
	const start = trimmed.indexOf("{");
	const end = trimmed.lastIndexOf("}");
	if (start >= 0 && end > start)
		return JSON.parse(trimmed.slice(start, end + 1));
	throw new Error("Worker did not return JSON");
}

function findAssistantText(messages) {
	for (let i = messages.length - 1; i >= 0; i--) {
		const message = messages[i];
		if (message.role !== "assistant") continue;
		for (const part of message.content || [])
			if (part.type === "text") return part.text;
	}
	return "";
}

function workerPrompt(chunk) {
	return `Review exactly this assigned change unit. Your cwd is the PR-head worktree. Read relevant code and diff context, but do not modify files or run destructive commands.\n\nAssigned unit:\n${JSON.stringify(chunk, null, 2)}\n\nReturn JSON only in this schema:\n{"acknowledged_ranges":[{"start":number,"end":number}],"findings":[{"line":number,"severity":"error|warning|info","mechanism":"concrete failure mechanism","fix":"concrete fix"}]}\n\nAcknowledge every assigned range verbatim. Findings must be on an assigned changed line. Use an empty findings array when clean.`;
}

async function reviewChunk(cwd, chunk, signal) {
	// A separate Pi process gives each unit an isolated context and avoids relying
	// on SDK module resolution from a package-installed extension.
	return new Promise((resolvePromise, reject) => {
		const child = spawn(
			"pi",
			[
				"--mode",
				"json",
				"-p",
				"--no-session",
				"--tools",
				"read,bash,grep,find,ls",
				workerPrompt(chunk),
			],
			{ cwd, stdio: ["ignore", "pipe", "pipe"] },
		);
		let stdout = "";
		let stderr = "";
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (data) => {
			stdout += data;
		});
		child.stderr.on("data", (data) => {
			stderr += data;
		});
		const abort = () => child.kill("SIGTERM");
		signal?.addEventListener("abort", abort, { once: true });
		child.on("error", (error) => reject(error));
		child.on("close", (code) => {
			signal?.removeEventListener("abort", abort);
			if (code !== 0)
				return reject(new Error(stderr || `Pi worker exited ${code}`));
			try {
				const events = stdout
					.split("\n")
					.filter(Boolean)
					.map((line) => JSON.parse(line));
				const messages = events
					.filter((event) => event.type === "message_end")
					.map((event) => event.message);
				resolvePromise(parseJson(findAssistantText(messages)));
			} catch (error) {
				reject(error);
			}
		});
	});
}

async function createPrWorktree(prUrl, cwd) {
	const pr = JSON.parse(
		await command("gh", [
			"pr",
			"view",
			prUrl,
			"--json",
			"number,baseRefOid,headRefOid,headRepository",
		]).then((r) => r.stdout),
	);
	const repoName = pr.headRepository?.name;
	if (!repoName || !pr.headRefOid)
		throw new Error("Could not resolve PR head repository and SHA.");

	// The invoking project may be a workspace directory; accept a matching direct child.
	let repo = cwd;
	try {
		const remote = (
			await command("git", ["config", "--get", "remote.origin.url"], cwd)
		).stdout;
		if (!remote.includes(repoName)) throw new Error("different repository");
	} catch {
		const entries = await (await import("node:fs/promises")).readdir(cwd, {
			withFileTypes: true,
		});
		const match = entries.find(
			(entry) => entry.isDirectory() && entry.name === repoName,
		);
		if (!match)
			throw new Error(`No local checkout for ${repoName} under ${cwd}.`);
		repo = resolvePath(cwd, match.name);
	}

	await command("git", ["fetch", "origin", pr.headRefOid], repo);
	const worktree = await mkdtemp(join(tmpdir(), `luke-pr-${pr.number}-`));
	await rm(worktree, { recursive: true, force: true });
	await command(
		"git",
		["worktree", "add", "--detach", worktree, pr.headRefOid],
		repo,
	);
	return { repo, worktree, base: pr.baseRefOid, head: pr.headRefOid };
}

export async function orchestrateReview({
	lukeBin,
	target,
	cwd,
	signal,
	onProgress = () => {},
}) {
	if (!target?.trim()) throw new Error("A review target is required.");
	let worktree = null;
	let repo = null;
	let base = null;
	try {
		let reviewCwd = cwd;
		let args = ["review", "start", ...target.trim().split(/\s+/)];
		const isPrTarget =
			target.includes("github.com/") ||
			target.startsWith("--pr ") ||
			/^[^\s/]+\/[^\s#]+#\d+$/.test(target.trim());
		if (isPrTarget) {
			const prUrl = target.startsWith("--pr ")
				? target.slice(5).trim()
				: target.trim();
			const resolved = await createPrWorktree(prUrl, cwd);
			worktree = resolved.worktree;
			repo = resolved.repo;
			base = resolved.base;
			reviewCwd = worktree;
			args = ["review", "start", "--pr", prUrl];
			onProgress(`Using PR head ${resolved.head.slice(0, 12)} in ${worktree}`);
			// The graph must describe the fixed PR source, never an arbitrary checkout.
			await runLuke(lukeBin, ["init", worktree], worktree);
		}

		const started = parseJson((await runLuke(lukeBin, args, reviewCwd)).stdout);
		onProgress(
			`Planned ${started.coverage.chunks} units / ${started.coverage.eligible_changed_lines} changed lines.`,
		);
		const findings = [];
		let processed = 0;
		const processItem = async (item) => {
			let result;
			let lastError;
			for (let attempt = 1; attempt <= 2; attempt++) {
				try {
					result = await reviewChunk(reviewCwd, item.chunk, signal);
					const resultPath = join(
						tmpdir(),
						`luke-result-${started.run_id}-${item.chunk.id}.json`,
					);
					await writeFile(resultPath, JSON.stringify(result), { mode: 0o600 });
					try {
						await runLuke(
							lukeBin,
							[
								"review",
								"submit",
								started.run_id,
								String(item.chunk.id),
								resultPath,
							],
							reviewCwd,
						);
					} finally {
						await rm(resultPath, { force: true });
					}
					break;
				} catch (error) {
					lastError = error;
					onProgress(`Unit ${item.chunk.id} attempt ${attempt} failed.`);
				}
			}
			if (!result) {
				await runLuke(
					lukeBin,
					["review", "block", started.run_id, String(item.chunk.id)],
					reviewCwd,
				).catch(() => {});
				throw lastError;
			}
			return { item, result };
		};
		while (!signal?.aborted) {
			const batch = [];
			for (let i = 0; i < MAX_CONCURRENCY; i++) {
				const next = await runLuke(
					lukeBin,
					["review", "next", started.run_id],
					reviewCwd,
				);
				if (!next.stdout.trim()) break;
				batch.push(parseJson(next.stdout));
			}
			if (batch.length === 0) break;
			const completed = await Promise.all(batch.map(processItem));
			for (const { item, result } of completed)
				for (const finding of result.findings || [])
					findings.push({ ...finding, file: item.chunk.file });
			processed += completed.length;
			onProgress(`Reviewed ${processed}/${started.coverage.chunks} units.`);
		}
		if (signal?.aborted)
			throw new Error("Review aborted; run data retained for inspection.");
		let verification = {
			status: "unavailable",
			detail: "No PR base SHA available.",
		};
		if (base) {
			try {
				await command("git", ["diff", "--check", `${base}...HEAD`], reviewCwd);
				verification = { status: "passed", detail: "git diff --check" };
			} catch (error) {
				verification = {
					status: "failed",
					detail: error.detail || error.message || "git diff --check failed",
				};
			}
		}
		await runLuke(lukeBin, ["review", "finalize", started.run_id], reviewCwd);
		return {
			runId: started.run_id,
			coverage: started.coverage,
			findings,
			verification,
			repo,
			headWorktree: worktree,
		};
	} finally {
		if (worktree && repo) {
			await command(
				"git",
				["worktree", "remove", "--force", worktree],
				repo,
			).catch(() => rm(worktree, { recursive: true, force: true }));
		}
	}
}
