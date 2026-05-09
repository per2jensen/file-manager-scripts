#! /bin/bash

# License
# All scripts are licensed under the 
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html


# Remove most metadata JPEG photos and leave only a few.
# Can easily be changed to "full paranoia scrubbing" :-)
# The engine is https://github.com/per2jensen/scrubexif


echo "===>>>  Running $0 at $(date --iso-8601=seconds)" | tee -a /tmp/scrubexif.log

echo "DEBUG: '$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS'" | cat -A | tee -a /tmp/scrubexif.log


# Build args array
ARGS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ARGS+=("$line")
done <<< "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"

# Guard: ensure at least one file was selected
if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "$0: No files selected, exiting." | tee -a /tmp/scrubexif.log
    notify-send -u critical "scrubexif ❌" "No files selected — aborting to avoid cleaning entire directory"
    exit 1
fi

# All files must be in the same dir for a single mount
FILE_DIR=$(dirname "${ARGS[0]}")

# Build basename args for the container
BASENAMES=()
for f in "${ARGS[@]}"; do
    BASENAMES+=("$(basename "$f")")
done

docker run --rm \
    --read-only --security-opt no-new-privileges \
    --tmpfs /tmp \
    -v "$FILE_DIR:/photos" \
    per2jensen/scrubexif:latest --clean-inline "${BASENAMES[@]}" | tee -a /tmp/scrubexif.log


# Parse the SCRUBEXIF_SUMMARY line
SUMMARY_LINE=$(grep "SCRUBEXIF_SUMMARY" /tmp/scrubexif.log | tail -1)
SCRUBBED=$(echo "$SUMMARY_LINE" | grep -oP 'scrubbed=\K[0-9]+')
SKIPPED=$(echo "$SUMMARY_LINE"  | grep -oP 'skipped=\K[0-9]+')
ERRORS=$(echo "$SUMMARY_LINE"   | grep -oP 'errors=\K[0-9]+')
TOTAL=$(echo "$SUMMARY_LINE"    | grep -oP 'total=\K[0-9]+')

if [[ "$ERRORS" -gt 0 || "$SKIPPED" -gt 0 ]]; then
    notify-send -u critical "scrubexif ❌" "Scrubbed $SCRUBBED/$TOTAL files — skipped: $SKIPPED, errors: $ERRORS"
else
    notify-send "scrubexif ✅" "Scrubbed $SCRUBBED/$TOTAL files successfully"
fi




