#!/bin/bash
# install.sh — Zotero → DEVONthink installer
# https://github.com/jimfalk/zotero-devonthink

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.zoteroDT.watcher"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
WATCHER_DEST="/usr/local/bin/zoteroDT_watcher.sh"
CONFFILE="$HOME/.zoteroDT.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}!${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${NC}"; }
prompt()  { echo -en "${BOLD}$*${NC}"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
header "Checking prerequisites…"

# macOS version
os_ver=$(sw_vers -productVersion)
os_major=$(echo "$os_ver" | cut -d. -f1)
if [ "$os_major" -lt 11 ]; then
    error "macOS 11 Big Sur or later required (found $os_ver)"
    exit 1
fi
info "macOS $os_ver"

# DEVONthink
if ! osascript -e 'tell application "System Events" to (name of processes) contains "DEVONthink 3"' 2>/dev/null | grep -q true; then
    warn "DEVONthink does not appear to be running. It must be open during import."
    prompt "Continue anyway? [y/N] "; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
else
    info "DEVONthink is running"
fi

# Zotero
if ! ls ~/Library/Application\ Support/Zotero 2>/dev/null | grep -q .; then
    warn "Zotero application support folder not found — is Zotero installed?"
fi

# curl and python3 (ship with macOS, belt-and-suspenders check)
for cmd in curl python3 osascript launchctl; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
        exit 1
    fi
done
info "Required commands available"

# ── Automation permission ─────────────────────────────────────────────────────
# Trigger the macOS Automation permission prompt now (while Terminal is in the
# foreground) so the launchd agent can control DEVONthink without a UI prompt.
header "Requesting Automation permission for DEVONthink…"
echo "  If a system dialog appears asking to allow Terminal to control DEVONthink,"
echo "  click OK."
osascript -e 'tell application id "com.devon-technologies.think" to get name' \
    2>/dev/null || \
    osascript -e 'tell application "DEVONthink 3" to get name' 2>/dev/null || true
info "Automation permission step complete"

# ── Detect Zotero storage path ────────────────────────────────────────────────
header "Detecting Zotero storage path…"

ZOTERO_STORAGE=""
for candidate in \
    "$HOME/Zotero/storage" \
    "$HOME/Documents/Zotero/storage" \
    "$HOME/Library/Application Support/Zotero/storage"
do
    if [ -d "$candidate" ]; then
        ZOTERO_STORAGE="$candidate"
        info "Found: $candidate"
        break
    fi
done

if [ -z "$ZOTERO_STORAGE" ]; then
    warn "Could not auto-detect Zotero storage folder."
fi

prompt "Zotero storage path [${ZOTERO_STORAGE:-enter path}]: "
read -r input
if [ -n "$input" ]; then ZOTERO_STORAGE="$input"; fi

if [ ! -d "$ZOTERO_STORAGE" ]; then
    error "Directory does not exist: $ZOTERO_STORAGE"
    exit 1
fi
info "Storage: $ZOTERO_STORAGE"

# ── Zotero credentials ────────────────────────────────────────────────────────
header "Zotero API credentials"
echo "  Find your user ID at: https://www.zotero.org/settings"
echo "  It appears as 'Your userID for use in API calls' on that page."
echo ""

prompt "Zotero user ID (numbers only): "
read -r ZOTERO_USER_ID
if ! [[ "$ZOTERO_USER_ID" =~ ^[0-9]+$ ]]; then
    error "User ID must be numeric"
    exit 1
fi

echo ""
echo "  Create an API key at: https://www.zotero.org/settings/keys"
echo "  Required scopes: Allow library access + Allow notes access (read + write)"
echo ""

prompt "Zotero API key: "
read -r ZOTERO_API_KEY
if [ -z "$ZOTERO_API_KEY" ]; then
    error "API key cannot be empty"
    exit 1
fi

# Verify credentials
info "Verifying Zotero credentials…"
http_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Zotero-API-Key: $ZOTERO_API_KEY" \
    "https://api.zotero.org/users/${ZOTERO_USER_ID}/items?limit=1")
if [ "$http_status" != "200" ]; then
    error "Zotero API returned HTTP $http_status — check your user ID and API key"
    exit 1
fi
info "Zotero credentials verified"

# ── DEVONthink database ───────────────────────────────────────────────────────
header "DEVONthink destination"

echo "  Available databases (requires DEVONthink to be running with databases open):"

# Try bundle ID first, fall back to app name (more compatible with older macOS)
db_list=$(osascript -e 'tell application id "com.devon-technologies.think" to get name of databases' 2>/dev/null || \
          osascript -e 'tell application "DEVONthink 3" to get name of databases' 2>/dev/null || true)

if [ -n "$db_list" ]; then
    echo "  $db_list" | tr ',' '\n' | sed 's/^ */    • /'
else
    # Distinguish between permissions failure and no open databases
    dt_running=$(osascript -e 'tell application "System Events" to (name of processes) contains "DEVONthink 3"' 2>/dev/null || true)
    if [ "$dt_running" != "true" ]; then
        warn "DEVONthink does not appear to be running — please open it and re-run the installer"
        prompt "Continue anyway? [y/N] "; read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    else
        warn "DEVONthink is running but no databases are listed."
        echo ""
        echo "  This usually means either:"
        echo "    (a) No databases are open in DEVONthink — open one and re-run the installer, or"
        echo "    (b) Terminal lacks Automation permission to control DEVONthink."
        echo "        Fix: System Preferences → Security & Privacy → Privacy → Automation"
        echo "             Check the box for DEVONthink 3 under Terminal."
        echo ""
        prompt "Continue and enter the database name manually? [y/N] "; read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi
fi

echo ""
echo "  Leave blank to use the Global Inbox (recommended default)."
prompt "DEVONthink database name [Global Inbox]: "
read -r DT_DB
DT_DB="${DT_DB:-Global Inbox}"

prompt "DEVONthink group/folder within database (leave blank for Inbox): "
read -r DT_GROUP

# ── Write config file ─────────────────────────────────────────────────────────
header "Writing configuration…"

cat > "$CONFFILE" << EOF
# ~/.zoteroDT.conf — Zotero → DEVONthink watcher configuration
# Created by install.sh on $(date)

ZOTERO_USER_ID="${ZOTERO_USER_ID}"
ZOTERO_API_KEY="${ZOTERO_API_KEY}"
ZOTERO_STORAGE="${ZOTERO_STORAGE}"
DT_DB="${DT_DB}"
DT_GROUP="${DT_GROUP}"
LOG="/tmp/zoteroDT_run.log"
EOF

chmod 600 "$CONFFILE"
info "Config written to $CONFFILE (permissions: 600)"

# ── Install watcher script ────────────────────────────────────────────────────
header "Installing watcher script…"

if [ ! -d /usr/local/bin ]; then
    sudo mkdir -p /usr/local/bin
fi

sudo cp "$SCRIPT_DIR/zoteroDT_watcher.sh" "$WATCHER_DEST"
sudo chmod 755 "$WATCHER_DEST"
info "Installed $WATCHER_DEST"

# ── Install launchd agent ─────────────────────────────────────────────────────
header "Installing launchd agent…"

mkdir -p "$HOME/Library/LaunchAgents"

# Unload and remove any previous installation under the old label
OLD_PLIST="$HOME/Library/LaunchAgents/com.jimfalk.zoteroDT.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    warn "Removed old agent (com.jimfalk.zoteroDT)"
fi

# Substitute storage path in plist template
sed "s|__ZOTERO_STORAGE__|${ZOTERO_STORAGE}|g" \
    "$SCRIPT_DIR/com.zoteroDT.watcher.plist.template" > "$PLIST_DEST"

# Unload any previous version of the new label
launchctl unload "$PLIST_DEST" 2>/dev/null || true

launchctl load "$PLIST_DEST"
info "launchd agent loaded: $PLIST_LABEL"

# ── Self-test ─────────────────────────────────────────────────────────────────
header "Running self-test…"

# Initialise statefile if needed so the first real event isn't missed
STATEFILE="$HOME/.zoteroDT_lastrun"
if [ ! -f "$STATEFILE" ]; then touch "$STATEFILE"; fi

TEST_DIR="$ZOTERO_STORAGE/_zoteroDT_test_$$"
# Record log size before test so we only check new lines
LOG_BEFORE=$(wc -l < /tmp/zoteroDT_run.log 2>/dev/null || echo 0)
mkdir "$TEST_DIR"
echo "  Created test folder: $TEST_DIR"
echo "  Waiting up to 15 s for watcher to fire…"

fired=false
for i in $(seq 1 15); do
    sleep 1
    if tail -n "+$((LOG_BEFORE + 1))" /tmp/zoteroDT_run.log 2>/dev/null | grep -q "Watcher triggered"; then
        fired=true
        break
    fi
done

rmdir "$TEST_DIR" 2>/dev/null || true

if $fired; then
    info "Watcher fired successfully"
else
    warn "Watcher did not fire within 15 s — check /tmp/zoteroDT_err.log"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo "  Config:       $CONFFILE"
echo "  Watcher:      $WATCHER_DEST"
echo "  Agent:        $PLIST_DEST"
echo "  Log:          /tmp/zoteroDT_run.log"
echo ""
echo "  The watcher will now run automatically whenever Zotero saves a new"
echo "  attachment to $ZOTERO_STORAGE."
echo ""
echo "  To uninstall, run: ./uninstall.sh"
