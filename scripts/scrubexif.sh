#! /bin/bash
# License
# All scripts are licensed under the
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html
#
# Remove most metadata from JPEG photos and leave only a few.
# Can easily be changed to "full paranoia scrubbing" :-)
# The engine is my https://github.com/per2jensen/scrubexif
#
# IMPORTANT: At least one file must be selected in Nautilus before running
# this script. Without a selection, scrubexif would process the entire
# directory — stripping exif data from all photos, which is irreversible.

LOG=/tmp/scrubexif.log
MAX_LOG=102400   # 100k
HALF_LOG=51200   #  50k


log() {
    echo "$*" | tee -a "$LOG"
}

abort() {
    log "$0: ERROR: $*"
    notify-send -u critical "scrubexif ❌" "$*"
    exit 1
}

# trim the log file if it exceeds the max size, keeping only the last half of it
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -gt "$MAX_LOG" ]; then
    tail -c $HALF_LOG "$LOGFILE" | tail -n +2 > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
fi

log "===>>> $(date --iso-8601=seconds) - running $0"
#echo "DEBUG: '$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS'" | cat -A | tee -a "$LOG"

# Check docker is available
command -v docker &>/dev/null || abort "docker is not installed or not in PATH"
docker info &>/dev/null      || abort "docker daemon is not running or current user cannot reach it"

# Build args array
ARGS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ARGS+=("$line")
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

# Guard: ensure at least one file was selected
if [[ ${#ARGS[@]} -eq 0 ]]; then
    abort "No files selected — aborting to avoid scrubbing entire directory"
fi

# Guard: all files must exist
for f in "${ARGS[@]}"; do
    [[ -f "$f" ]] || abort "File not found: $f"
done

# Guard: all files must be in the same directory
FILE_DIR=$(dirname "${ARGS[0]}")
for f in "${ARGS[@]}"; do
    [[ "$(dirname "$f")" == "$FILE_DIR" ]] || abort "Files must all be in the same directory — found files in multiple directories"
done

# Build basename args for the container
BASENAMES=()
for f in "${ARGS[@]}"; do
    BASENAMES+=("$(basename "$f")")
done

log "Processing ${#BASENAMES[@]} file(s) in $FILE_DIR"

docker run --rm \
    --read-only --security-opt no-new-privileges \
    --tmpfs /tmp \
    -v "$FILE_DIR:/photos" \
    per2jensen/scrubexif:latest --clean-inline "${BASENAMES[@]}" | tee -a "$LOG"

# Parse the SCRUBEXIF_SUMMARY line
SUMMARY_LINE=$(grep "SCRUBEXIF_SUMMARY" "$LOG" | tail -1)
SCRUBBED=$(echo "$SUMMARY_LINE" | grep -oP 'scrubbed=\K[0-9]+')
SKIPPED=$(echo "$SUMMARY_LINE"  | grep -oP 'skipped=\K[0-9]+')
ERRORS=$(echo "$SUMMARY_LINE"   | grep -oP 'errors=\K[0-9]+')
TOTAL=$(echo "$SUMMARY_LINE"    | grep -oP 'total=\K[0-9]+')

# Check we actually got a summary — if not, docker or scrubexif likely failed
if [[ -z "$TOTAL" ]]; then
    abort "No summary line found — scrubexif may have failed. Check $LOG"
fi

if [[ "$ERRORS" -gt 0 || "$SKIPPED" -gt 0 ]]; then
    notify-send -u critical "scrubexif ❌" "Scrubbed $SCRUBBED/$TOTAL files — skipped: $SKIPPED, errors: $ERRORS"
else
    notify-send "scrubexif ✅" "Scrubbed $SCRUBBED/$TOTAL files successfully"
fi
