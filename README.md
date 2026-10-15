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

Checking your usage never uses up your usage — it only reads it.

It uses almost no CPU (refreshes every 10 minutes by default, down to every 2), stores everything locally in
`~/Library/Application Support/UsageBar/`, and sends nothing anywhere except the
services' own usage pages.

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
| **Codex** | Nothing, as long as you use the `codex` CLI / app and are logged in. |
| **Grok Bot** | Nothing, if the Grok Bot Mac app is installed. Otherwise type your % left manually. |
| **OpenCode Go** | Go to [opencode.ai/console](https://opencode.ai/console), open your Go page and copy its address (looks like `https://opencode.ai/console/org_…/go`). Paste it into **Console URL**, then click **Sign in to OpenCode…** in the menu and log in once. |
| **DeepSeek** | Endpoint URL: `https://api.deepseek.com/user/balance` — Token: your DeepSeek API key. |
| **Prices** | Type what you pay per month for each plan, exactly as on the receipt, and pick that receipt's currency next to it. The Spend row adds them up in your display currency. Leave blank anything you don't have. |
| **VPS** | Optional: price and next due date, for the renewal countdown. |

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

Quit UsageBar from its menu, delete `/Applications/UsageBar.app`, and optionally
`~/Library/Application Support/UsageBar/`.
