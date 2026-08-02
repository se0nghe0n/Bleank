# Bleank

English | [한국어](README.ko.md)

Claude Code status on the MagSafe 3 LED.

| Claude is | LED |
|---|---|
| thinking | amber, blinking |
| responding | green, blinking |
| done | green, solid |
| waiting on you (question / permission) | amber, solid |
| no session | back under macOS control |

**Amber, not red.** The MagSafe LED is a two-colour part — amber and green, no red element.
Change `let amber` in [main.swift](Sources/ClaudeLED/main.swift) if a future value turns out to do better.

**Only visible on MagSafe.** Charging over USB-C lights nothing. `ACLC` is also absent on
Macs without a MagSafe port (the daemon reports `SMC result = 132`).

## How it works

SMC writes need root; blinking needs a loop. So: one root daemon polls a state file,
and the hooks — which run as you — write a single word into it. No `sudo` in the hot path.

## Pi coding agent

Pi doesn't understand Claude Code's `hooks.json`, so
[`.pi/extensions/claude-led.ts`](.pi/extensions/claude-led.ts) mirrors the hooks as a Pi
extension. Same states, same state file:

| Pi event | State |
|---|---|
| `input` (non-command), `before_agent_start`, `tool_execution_start` | thinking |
| `message_start` / `message_update` (assistant) | responding |
| `agent_settled` | done |
| `question` tool start | waiting |
| `session_shutdown` | system |

Install it once, globally (works in every project):

```bash
mkdir -p ~/.pi/agent/extensions && cp .pi/extensions/claude-led.ts ~/.pi/agent/extensions/
```

Restart Pi (or `/reload`) and send a prompt. Project-local alternative: just run Pi inside
this repo — `.pi/extensions/` is auto-discovered after the project is trusted. Both can
coexist with the Claude Code hooks; last writer wins.

## Install

```bash
tuist generate --no-open && tuist xcodebuild build -scheme ClaudeLED -destination "platform=macOS"
```

The product lands in `DerivedData/Bleank/Build/Products/Debug/claude-led`. Check the layout assumptions:

```bash
./DerivedData/Bleank/Build/Products/Debug/claude-led selftest
```

Plug in MagSafe and confirm the hardware responds — amber, green, off, then back to normal:

```bash
sudo ./DerivedData/Bleank/Build/Products/Debug/claude-led test
```

Install the daemon:

```bash
sudo cp DerivedData/Bleank/Build/Products/Debug/claude-led /usr/local/bin/ && sudo cp com.bleank.claude-led.plist /Library/LaunchDaemons/ && sudo launchctl load /Library/LaunchDaemons/com.bleank.claude-led.plist
```

Merge the hooks into your global Claude Code settings (backs up first):

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak 2>/dev/null; jq -s '.[0] * .[1]' ~/.claude/settings.json hooks.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Restart Claude Code and send a prompt.

## Uninstall

```bash
sudo launchctl unload /Library/LaunchDaemons/com.bleank.claude-led.plist && sudo rm /Library/LaunchDaemons/com.bleank.claude-led.plist /usr/local/bin/claude-led
```

The daemon restores system control on exit; remove the `hooks` block from `~/.claude/settings.json`.

## Known ceilings

- Blink is 1.25 Hz. Whether the SMC tolerates faster writes is untested — `halfPeriod`.
- macOS reasserts the LED on charging-state changes, so the daemon re-writes every 5s regardless.
- Two Claude Code sessions share one state file and one LED: last writer wins.
- If the agent exits without running its session-end hook (crash, `kill -9`), the state file goes
  stale; after 10 minutes the daemon hands the LED back to macOS — `staleTimeout`.
