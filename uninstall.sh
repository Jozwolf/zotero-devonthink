#!/bin/bash
# uninstall.sh — Zotero → DEVONthink uninstaller

set -euo pipefail

PLIST_LABEL="com.zoteroDT.watcher"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
WATCHER_DEST="/usr/local/bin/zoteroDT_watcher.sh"
CONFFILE="$HOME/.zoteroDT.conf"
STATEFILE="$HOME/.zoteroDT_lastrun"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }

echo -e "${BOLD}Zotero → DEVONthink uninstaller${NC}"
echo ""
echo "This will remove:"
echo "  $WATCHER_DEST"
echo "  $PLIST_DEST"
echo "  $STATEFILE"
echo ""
echo "It will NOT remove your config file ($CONFFILE)."
echo "Delete that manually if you want to remove your API key from disk."
echo ""
echo -en "${BOLD}Proceed? [y/N] ${NC}"; read -r ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Unload agent
if [ -f "$PLIST_DEST" ]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    info "Removed launchd agent"
else
    warn "Agent plist not found (already removed?)"
fi

# Remove watcher script
if [ -f "$WATCHER_DEST" ]; then
    sudo rm -f "$WATCHER_DEST"
    info "Removed $WATCHER_DEST"
else
    warn "$WATCHER_DEST not found (already removed?)"
fi

# Remove statefile
if [ -f "$STATEFILE" ]; then
    rm -f "$STATEFILE"
    info "Removed statefile"
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
if [ -f "$CONFFILE" ]; then
    echo ""
    echo "  Your config file still exists at $CONFFILE"
    echo "  It contains your Zotero API key. Delete it when no longer needed:"
    echo "    rm $CONFFILE"
fi
