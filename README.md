# UsageBar

A tiny macOS menu bar app that shows how much of your AI subscriptions you have left — all in one place:

- **Claude Code** — 5-hour and weekly limits
- **Codex / ChatGPT** — 5-hour and weekly limits
- **OpenCode Go** — 5-hour / week / month usage
- **Grok Bot** — weekly usage
- **DeepSeek** — API balance
- **Spend** — what you pay per month in total (in €, $ or £), plus a VPS renewal countdown

It warns you before you run dry: a notification at 25%, 10% and 0% left, and a
"burning fast" alert when your current pace would empty a limit within the hour.
Low numbers also turn orange/red in the menu bar. (Click **Allow** when macOS asks
about notifications.)

It also tracks your **pace**, on one line under each row: how fast you're using
it right now (%/h, from the 5-hour window) and your average burn this week
(%/day, from the weekly window), plus whether what's left lasts until the reset —
e.g. "4.2%/h · 9%/day · lasts until reset". It learns your usual speed in the
background and sends a "Slow down" alert when you're going twice as fast. DeepSeek
shows dollars per hour and per day, and how many days your balance lasts; the VPS disk
shows how fast it's growing and when it would fill up.

Checking your usage never uses up your usage — it only reads it.

It uses almost no CPU (refreshes every 3 minutes by default; the OpenCode console
page every 15, and only once you've set it up). Your settings and history stay on
your Mac in `~/Library/Application Support/UsageBar/` (readable only by you), and
the OpenCode sign-in lives in the app's own web storage. It talks only to the
services' own usage endpoints, plus a free exchange-rate service
(frankfurter.dev, falling back to open.er-api.com) for currency conversion.

Requires **macOS 14 (Sonoma) or newer**.

---

## Install

### Option A — download the app (easiest)

1. Download **UsageBar.zip** from the [latest release](../../releases/latest) and double-click it.
2. Drag **UsageBar.app** into your **Applications** folder.
3. Open Terminal and paste this once (the app isn't from the App Store, so macOS blocks it otherwise):

   ```bash
   xattr -dr com.apple.quarantine /Applications/UsageBar.app
   ```

4. Open UsageBar from Applications. A gauge icon appears in the menu bar (top right).

### Option B — build it yourself

```bash
git clone https://github.com/sketchmesome/UsageBar.git
cd UsageBar
./install.sh
```

If Swift isn't installed, the script pops up Apple's installer for the Command Line
Tools — accept it, then run `./install.sh` again. To update later: `git pull && ./install.sh`.

---

## Set up (click the menu bar icon → **Settings…**)

Most rows work by themselves — anything you don't use just shows "not connected"
and can be ignored.

| Service | What to do |
|---|---|
| **Claude Code** | Nothing, as long as you're logged in to Claude Code. If macOS asks for access to the "Claude Code-credentials" keychain item, click **Always Allow**. |
| **Codex** | Nothing, as long as the `codex` CLI is installed and logged in (UsageBar asks it for your limits). |
| **Grok Bot** | Nothing, if the Grok Bot Mac app is installed. Otherwise type your % left manually. |
| **OpenCode Go** | Go to [opencode.ai/console](https://opencode.ai/console), open your Go page and copy its address (looks like `https://opencode.ai/console/org_…/go`). Paste it into **Console URL**, then click **Sign in to OpenCode…** in the menu and log in once. Until a Console URL is set, UsageBar doesn't load the page at all. |
| **DeepSeek** | Endpoint URL: `https://api.deepseek.com/user/balance` — Token: your DeepSeek API key. |
| **Prices** | Type what you pay per month for each plan, exactly as on the receipt, and pick that receipt's currency next to it. The Spend row adds them up in your display currency. Leave blank anything you don't have. |
| **VPS** | Optional: price and next due date, for the renewal countdown. (Live disk/RAM stats and the disk-full forecast need your own stats endpoint.) |

Also in Settings: which numbers appear in the menu bar, display currency, and
**Launch at login** (on by default).

### Optional: Claude Code in the terminal

If you mostly use Claude Code in a terminal, you can add a backup data source that
also works offline. Copy the saver script somewhere, then add it as your status line
in `~/.claude/settings.json`:

```bash
cp Scripts/claude-statusline-saver.sh ~/.claude/usagebar-statusline.sh
```

```json
{ "statusLine": { "type": "command", "command": "bash ~/.claude/usagebar-statusline.sh" } }
```

---

## Uninstall

Turn off **Launch at login** in Settings, quit UsageBar from its menu, and delete
`/Applications/UsageBar.app`. To remove its data too:

```bash
rm -rf ~/Library/Application\ Support/UsageBar ~/Library/Caches/com.lanes.usagebar ~/Library/WebKit/com.lanes.usagebar ~/Library/HTTPStorages/com.lanes.usagebar*
```

If you added the Claude Code status line, remove it from `~/.claude/settings.json`
and delete `~/.claude/usagebar-statusline.sh`.
