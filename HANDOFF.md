# HANDOFF — UsageBar

## What it is
Native Swift (SwiftUI/AppKit) macOS menu bar app, macOS 14+. Shows usage left for Claude Code, Codex, OpenCode Go and Grok Bot, the DeepSeek API balance, a VPS price/renewal countdown and stats, and total monthly spend (€/$/£ via frankfurter.dev, fallback open.er-api.com). Near-zero CPU; launches at login (SMAppService).

## Data sources (read-only, no usage spent)
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` `rate_limits`, plus live `codex app-server` (`CodexSource.swift`, `CodexAppServer.swift`).
- Claude Code: `Scripts/claude-statusline-saver.sh` run from the Claude status line writes `claude.json` (`ClaudeSource.swift`).
- Grok Bot: weekly-usage cache in `~/Library/Application Support/Grok Bot/sand-client-persistence/` (`GrokSource.swift`).
- OpenCode Go: console page in a hidden WKWebView, with `opencode.db` estimate fallback (`OpenCode*.swift`).
- DeepSeek: balance API (`DeepSeekSource.swift`).
- VPS: optional stats endpoint + billing (`VPSBilling.swift`, `VPSDueSource.swift`).

Settings, tokens and history live only in `~/Library/Application Support/UsageBar/` on the Mac — never in this repo. Never commit them.

## Build / install
`./install.sh` (needs Xcode Command Line Tools): runs `Scripts/build_app.sh` -> `build/UsageBar.app`, copies it to /Applications (or ~/Applications), starts it.

## State
- `main` here is the public version (v1.2.2).
- The owner's Mac has newer local branches (`devilsbar-redesign`, `full-history`) with personal changes, not published here on purpose.
- Grok Bot price and "Other" cost are entered by hand in Settings.

## Next
- A second OVH VPS returns API error 460 in the VPS billing lookup — handle or skip it gracefully.
