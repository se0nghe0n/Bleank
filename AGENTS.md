# AGENTS.md — Bleank

Bleank shows coding-agent status (Claude Code, Codex, Pi) on the MacBook MagSafe 3 LED. A root daemon (`claude-led`, Swift command-line tool) polls `/tmp/claude-led.state` and drives the LED through SMC. Each agent integration only writes one word to that file: `thinking`, `responding`, `done`, `waiting`, or `system`.

## Layout
- `Sources/ClaudeLED/main.swift`: the daemon. SMC keys, colours, and the blink loop live here.
- `Project.swift`, `Tuist.swift`: Tuist project (macOS 12+ command-line target `ClaudeLED`).
- `hooks.json`: Claude Code hooks. `.codex/hooks.json`: Codex hooks. `.pi/extensions/claude-led.ts`: Pi extension.
- `com.bleank.claude-led.plist`: LaunchDaemon definition.
- `README.md` and `README.ko.md`: keep both in sync when behaviour or the install steps change.

## Build and verify
```sh
tuist generate --no-open && tuist xcodebuild build -scheme ClaudeLED -destination "platform=macOS"
```
- After editing the Pi extension, run `/reload` in Pi and check each state transition by hand.
- The global copy at `~/.pi/agent/extensions/claude-led.ts` also loads in this repo. If it differs from the project copy, both write to the same state file and the last writer wins.

## Rules
- Anything that needs `sudo` (`claude-led test`, copying to `/usr/local/bin`, `launchctl load/unload`) changes the machine. Give the command to the user instead of running it.
- Keep the five state words and the state-file path identical across Claude Code, Codex, and Pi.
- The MagSafe LED is amber and green only, so don't add red states.
