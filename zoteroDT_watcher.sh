#!/bin/bash
# zoteroDT_watcher.sh — Zotero → DEVONthink watcher
# Reads configuration from ~/.zoteroDT.conf

CONFFILE="$HOME/.zoteroDT.conf"

if [ ! -f "$CONFFILE" ]; then
    echo "$(date '+%H:%M:%S') ERROR: config file not found: $CONFFILE" >> /tmp/zoteroDT_run.log
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFFILE"

# Defaults for optional config keys
ZOTERO_STORAGE="${ZOTERO_STORAGE:-$HOME/Zotero/storage}"
DT_DB="${DT_DB:-Global Inbox}"
DT_GROUP="${DT_GROUP:-}"
LOGFILE="${LOG:-/tmp/zoteroDT_run.log}"
STATEFILE="$HOME/.zoteroDT_lastrun"
PENDINGFILE="$HOME/.zoteroDT_pending"   # tab-separated: KEY \t DT_LINK \t RETRY_COUNT
MAX_RETRIES=10
ZOTERO_API_BASE="https://api.zotero.org/users/${ZOTERO_USER_ID}/items"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOGFILE"; /usr/bin/logger -t ZoteroDT "$*"; }

# Post a child note to the Zotero parent record containing the DT deep link
post_note() {
    local key="$1" parent="$2" dt_link="$3"
    local payload
    payload=$(python3 -c "
import json, sys
p, l = sys.argv[1], sys.argv[2]
q = chr(34)
n = '<p><strong>DEVONthink</strong></p><p><a href=' + q + l + q + '>' + l + '</a></p>'
print(json.dumps([{'itemType':'note','parentItem':p,'note':n,'tags':[],'collections':[],'relations':{}}]))
" "$parent" "$dt_link")

    curl -s -X POST --max-time 15 \
        -H "Zotero-API-Key: $ZOTERO_API_KEY" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$ZOTERO_API_BASE" > /dev/null

    log "Done: $key"
}

# Look up parentItem for a key via the Zotero web API
lookup_parent() {
    local key="$1"
    curl -s --max-time 10 \
        -H "Zotero-API-Key: $ZOTERO_API_KEY" \
        "https://api.zotero.org/users/${ZOTERO_USER_ID}/items/$key" | \
        python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('data', {}).get('parentItem', ''))
except Exception:
    print('')
"
}

# Retry any keys that previously had no parent record
process_pending() {
    [ ! -f "$PENDINGFILE" ] && return
    local tmp
    tmp=$(mktemp)
    while IFS=$'\t' read -r key dt_link retries; do
        [ -z "$key" ] && continue
        retries=$((retries + 1))
        if [ "$retries" -gt "$MAX_RETRIES" ]; then
            log "Giving up on pending $key after $MAX_RETRIES retries"
            continue  # drop from pending file
        fi
        local parent
        parent=$(lookup_parent "$key")
        if [ -n "$parent" ]; then
            log "Pending resolved: $key → parent $parent"
            post_note "$key" "$parent" "$dt_link"
        else
            log "Pending retry $retries/$MAX_RETRIES: $key"
            printf '%s\t%s\t%s\n' "$key" "$dt_link" "$retries" >> "$tmp"
        fi
    done < "$PENDINGFILE"
    mv "$tmp" "$PENDINGFILE"
}

process_key() {
    local key="$1"
    local folder="$ZOTERO_STORAGE/$key"
    log "Processing: $key"

    # Poll for PDF up to 2 minutes (40 × 3 s)
    local pdf="" sz1 sz2
    for i in $(seq 1 40); do
        pdf=$(find "$folder" -maxdepth 1 -iname '*.pdf' -print | head -1)
        if [ -n "$pdf" ]; then
            sz1=$(stat -f%z "$pdf" 2>/dev/null || echo 0)
            sleep 3
            sz2=$(stat -f%z "$pdf" 2>/dev/null || echo 0)
            if [ "$sz1" = "$sz2" ] && [ "${sz1:-0}" -gt 0 ]; then break; fi
            pdf=""
        fi
        sleep 3
    done

    if [ -z "$pdf" ]; then log "No PDF for $key"; return; fi
    log "PDF ready: $pdf"

    # Import to DEVONthink
    local dt_link
    if [ -z "$DT_GROUP" ]; then
        dt_link=$(osascript - "$pdf" "$DT_DB" << 'SCPT'
on run argv
    set pdfPath to item 1 of argv
    set dbName to item 2 of argv
    tell application "DEVONthink 3"
        if dbName is "Global Inbox" then
            set tgt to inbox
        else
            set theDB to database dbName
            set tgt to root of theDB
        end if
        set r to import pdfPath to tgt
        return reference URL of r
    end tell
end run
SCPT
        )
    else
        dt_link=$(osascript - "$pdf" "$DT_DB" "$DT_GROUP" << 'SCPT'
on run argv
    set pdfPath to item 1 of argv
    set dbName to item 2 of argv
    set grpName to item 3 of argv
    tell application "DEVONthink 3"
        set theDB to database dbName
        set rootGrp to root of theDB
        set tgt to missing value
        repeat with k in (children of rootGrp)
            if name of k is grpName then
                set tgt to k
                exit repeat
            end if
        end repeat
        if tgt is missing value then error "Group not found: " & grpName
        set r to import pdfPath to tgt
        return reference URL of r
    end tell
end run
SCPT
        )
    fi

    if [ -z "$dt_link" ]; then log "DEVONthink import failed for $key"; return; fi
    log "DT link: $dt_link"

    # Look up Zotero parent
    local parent
    parent=$(lookup_parent "$key")

    if [ -z "$parent" ]; then
        log "No parentItem for $key — queued for retry"
        printf '%s\t%s\t%s\n' "$key" "$dt_link" "0" >> "$PENDINGFILE"
        return
    fi

    log "Parent: $parent"
    post_note "$key" "$parent" "$dt_link"
}

# ── Main ─────────────────────────────────────────────────────────────────────
log "Watcher triggered"
MARKER=$(mktemp)

if [ ! -f "$STATEFILE" ]; then
    mv "$MARKER" "$STATEFILE"
    log "Initialised statefile"
    exit 0
fi

new_folders=$(find "$ZOTERO_STORAGE" -maxdepth 1 -mindepth 1 -type d -newer "$STATEFILE" 2>/dev/null)
mv "$MARKER" "$STATEFILE"

# Always process any previously queued keys first
process_pending

if [ -z "$new_folders" ]; then
    log "No new folders found"
    exit 0
fi

while IFS= read -r folder; do
    key=$(basename "$folder")
    log "Found candidate: $key (len=${#key})"
    if [[ ${#key} -eq 8 ]]; then
        process_key "$key"
    fi
done <<< "$new_folders"
