/**
 * Bleank: Pi coding agent → MagSafe LED bridge.
 *
 * Pi doesn't understand Claude Code's hooks.json, so this extension mirrors it
 * using Pi's event system. It writes one word into the same state file the
 * claude-led daemon polls:
 *
 *   thinking    → amber, blinking   (agent is working)
 *   responding  → green, blinking   (assistant is streaming text)
 *   done        → green, solid      (agent settled, nothing left to run)
 *   waiting     → amber, solid      (agent blocked on you — question tool)
 *   system      → back to macOS     (session ended)
 *
 * Install (global, all projects):
 *   cp .pi/extensions/claude-led.ts ~/.pi/agent/extensions/
 *
 * Project-local alternative: just run pi inside this repo — .pi/extensions/
 * is auto-discovered. Either way, /reload after installing.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";

const STATE_FILE = "/tmp/claude-led.state";

let lastState = "";

function setState(state: string): void {
	if (state === lastState) return;
	try {
		writeFileSync(STATE_FILE, state);
		lastState = state;
	} catch {
		// Daemon not installed or file unwritable — LED stays under macOS control.
		// Reset the cache so a later write retries instead of being skipped.
		lastState = "";
	}
}

export default function (pi: ExtensionAPI) {
	// User submitted a prompt → the agent will start working.
	pi.on("input", (event) => {
		// Slash commands (skills, templates, builtins) don't necessarily run an agent.
		if (event.text.startsWith("/")) return;
		setState("thinking");
	});

	// A low-level agent run is starting (covers steer/follow-up and anything `input` missed).
	pi.on("before_agent_start", () => setState("thinking"));

	// Tool use = working.
	pi.on("tool_execution_start", (event) => {
		if (event.toolName === "question") {
			// The question tool blocks on the user — solid amber "needs you".
			setState("waiting");
		} else {
			setState("thinking");
		}
	});

	// Assistant messages (tool-call messages included) = responding.
	// message_update is per-token; the state cache makes the extra writes no-ops.
	pi.on("message_start", (event) => {
		if (event.message.role === "assistant") setState("responding");
	});
	pi.on("message_update", (event) => {
		if (event.message.role === "assistant") setState("responding");
	});

	// No retry/compaction/follow-up left — the agent is truly done.
	pi.on("agent_settled", () => setState("done"));

	// Session ending (quit, /new, /resume, fork) → hand the LED back to macOS.
	pi.on("session_shutdown", () => setState("system"));
}
