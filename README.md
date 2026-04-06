# Zotero → DEVONthink

Automatically imports new Zotero attachment PDFs into DEVONthink and posts the `x-devonthink-item://` link back to the Zotero parent record as a child note.

## How it works

1. A **launchd WatchPaths agent** fires whenever Zotero saves a new file to your storage folder.
2. The watcher script finds the new attachment folder, polls until the PDF is fully written, then imports it into DEVONthink.
3. The script queries the Zotero web API to find the parent item, then posts a child note containing the DEVONthink deep link.

## Prerequisites

| Requirement | Minimum version |
|---|---|
| macOS | 11 Big Sur or later (tested on Sequoia 15.7.4) |
| DEVONthink | 3.x |
| Zotero | 6.x, with local storage (not cloud-only) |
| Zotero API key | Read + write access to your personal library |

`curl`, `python3`, and `osascript` ship with macOS and require no separate installation.

## Installation

```bash
git clone https://github.com/jimfalk/zotero-devonthink.git
cd zotero-devonthink
bash install.sh
```

The installer will:

1. Check prerequisites (macOS version, DEVONthink running, required commands)
2. Auto-detect your Zotero storage path
3. Prompt for your Zotero user ID and API key
4. List available DEVONthink databases and prompt for destination
5. Write `~/.zoteroDT.conf` (permissions 600 — only readable by you)
6. Install `zoteroDT_watcher.sh` to `/usr/local/bin/`
7. Install and load the launchd agent
8. Run a quick self-test to confirm the watcher fires

### Where to find your Zotero credentials

- **User ID:** https://www.zotero.org/settings → *"Your userID for use in API calls"*
- **API key:** https://www.zotero.org/settings/keys → New key → enable *Allow library access* + *Allow notes access* (read **and** write)

## Configuration

The config file lives at `~/.zoteroDT.conf`:

```bash
ZOTERO_USER_ID="1234567"
ZOTERO_API_KEY="your_api_key_here"
ZOTERO_STORAGE="/Users/you/Zotero/storage"
DT_DB="Global Inbox"
DT_GROUP=""
LOG="/tmp/zoteroDT_run.log"
```

After editing the config, reload the agent:

```bash
launchctl unload ~/Library/LaunchAgents/com.zoteroDT.watcher.plist
launchctl load  ~/Library/LaunchAgents/com.zoteroDT.watcher.plist
```

## Uninstallation

```bash
bash uninstall.sh
```

Removes the watcher script, launchd agent, and statefile. Your config (`~/.zoteroDT.conf`) is kept so you can re-install without re-entering credentials. Delete it manually when no longer needed.

## Troubleshooting

**Watcher does not fire**

Check the launchd error log:
```bash
cat /tmp/zoteroDT_err.log
```
Confirm the agent is loaded:
```bash
launchctl list | grep zoteroDT
```
The `PID` column will be non-zero while the script is running.

**"DEVONthink import failed"**

DEVONthink must be running when the watcher fires. If you quit DEVONthink, re-open it — the next attachment will be processed normally.

**"No parentItem for … — skipping note"**

The attachment's parent item was not found in the Zotero web API. This can happen for orphan attachments (top-level items with no parent). The PDF is still imported into DEVONthink; only the back-link note is skipped.

**Zotero API returns HTTP 403**

Your API key may not have write access. Regenerate it at https://www.zotero.org/settings/keys with *Allow notes access* set to **read and write**.

**Check the log**

```bash
tail -40 /tmp/zoteroDT_run.log
```

## Known limitations

- macOS Folder Actions are broken for non-standard paths on Sequoia — this package uses `launchd WatchPaths` instead, which is kernel-level and reliable.
- Zotero's *local* API (localhost:23119) does not support write operations; the package uses the Zotero *web* API for posting notes.
- Only Zotero 8-character attachment keys are processed; top-level collection folders are ignored.

## Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/zoteroDT_watcher.sh` | Main watcher script |
| `~/Library/LaunchAgents/com.zoteroDT.watcher.plist` | launchd agent |
| `~/.zoteroDT.conf` | Configuration (created by installer) |
| `~/.zoteroDT_lastrun` | Statefile tracking last processed time |
