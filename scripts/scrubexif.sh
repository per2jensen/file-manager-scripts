#! /bin/bash
# License
# All scripts are licensed under the
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html
#
# Nautilus helper script — strips EXIF metadata from selected JPEG files
# using the scrubexif Docker container (https://github.com/per2jensen/scrubexif).
#
# USAGE
#   Select one or more JPEG files in Nautilus, then run this script via the
#   Scripts menu. At least one file must be selected — without a selection,
#   scrubexif would process the entire directory, which is irreversible.
#
# PREREQUISITES
#   - Docker installed and daemon running, accessible by the current user
#   - findmnt (part of util-linux, present on all modern Linux systems)
#   - notify-send (for desktop notifications)
#
# BEHAVIOUR
#   1. Guards: verifies Docker is available, at least one file is selected,
#      all selected files exist, and all are in the same directory.
#
#   2. Filesystem detection: uses findmnt to check whether the source
#      directory is on a filesystem that Docker's daemon cannot bind-mount
#      directly (FUSE mounts such as pCloud, NFS, CIFS/Samba).
#
#   3a. Local filesystem: Docker bind-mounts the source directory directly
#       and processes all selected files in a single container run.
#
#   3b. FUSE/NFS/CIFS filesystem:
#       - Safety check: verifies that the combined size of all selected files
#         fits in the temp directory (${TMPDIR:-/tmp}). If not, aborts with
#         a desktop notification showing the shortfall in MB.
#       - All selected files are copied to a local temp dir.
#       - Docker processes them all in a single container run.
#       - Processed files are copied back to the original directory.
#       - The temp dir is removed when the script exits (success or failure).
#
#   4. Result: a desktop notification reports how many files were scrubbed,
#      skipped, or errored. A full log is written to /tmp/scrubexif.log.

LOGFILE=/tmp/scrubexif.log
MAX_LOG=102400   # 100k
HALF_LOG=51200   #  50k


log() {
    echo "$*" | tee -a "$LOGFILE"
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
#echo "DEBUG: '$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS'" | cat -A | tee -a "$LOGFILE"

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

# Detect filesystems (FUSE, NFS, CIFS, etc.) that Docker daemon cannot bind-mount directly.
# If detected, copy files to a local temp dir, process there, then copy back.
FSTYPE=$(findmnt -n -o FSTYPE --target "$FILE_DIR" 2>/dev/null || echo "unknown")
NEEDS_COPY=false
if [[ "$FSTYPE" == fuse* || "$FSTYPE" == nfs* || "$FSTYPE" == cifs || "$FSTYPE" == smbfs ]]; then
    NEEDS_COPY=true
    # All selected files are copied to a local temp dir before Docker starts, and
    # Docker processes them all in one container run. Temp files are removed only
    # when the script exits (success or failure) via the EXIT trap — not per-file.
    # Check that all files fit in the temp dir before proceeding.
    TOTAL_BYTES=0
    for f in "${ARGS[@]}"; do
        TOTAL_BYTES=$(( TOTAL_BYTES + $(stat -c%s "$f") ))
    done
    AVAIL_BYTES=$(df --output=avail -B1 "${TMPDIR:-/tmp}" | tail -1 | tr -d ' ')
    if [[ $TOTAL_BYTES -ge $AVAIL_BYTES ]]; then
        NEED_MB=$(( TOTAL_BYTES / 1024 / 1024 ))
        AVAIL_MB=$(( AVAIL_BYTES / 1024 / 1024 ))
        abort "Not enough temp space to copy files: need ${NEED_MB}MB, only ${AVAIL_MB}MB free in ${TMPDIR:-/tmp}"
    fi
    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT
    log "Filesystem type '$FSTYPE' detected — copying files to local temp dir: $WORKDIR"
    for f in "${BASENAMES[@]}"; do
        cp "$FILE_DIR/$f" "$WORKDIR/"
    done
    MOUNT_DIR="$WORKDIR"
else
    MOUNT_DIR="$FILE_DIR"
fi

RUN_AS_UID=${RUN_AS_UID:-$(id -u)}
RUN_AS_GID=${RUN_AS_GID:-$(id -g)}
if [ "$RUN_AS_UID" -eq 0 ]; then
    abort "Running as root is not allowed"
fi
log "Running docker as UID:GID $RUN_AS_UID:$RUN_AS_GID"

docker run --rm \
    --user "$RUN_AS_UID:$RUN_AS_GID" \
    --read-only --security-opt no-new-privileges \
    --tmpfs /tmp \
    -v "$MOUNT_DIR:/photos" \
    per2jensen/scrubexif:latest --clean-inline "${BASENAMES[@]}" 2>&1 | tee -a "$LOGFILE"
DOCKER_EXIT=${PIPESTATUS[0]}

if $NEEDS_COPY && [[ $DOCKER_EXIT -eq 0 ]]; then
    log "Copying processed files back to $FILE_DIR"
    for f in "${BASENAMES[@]}"; do
        cp "$WORKDIR/$f" "$FILE_DIR/$f" || abort "Failed to copy processed file back: $f"
    done
fi

# Parse the SCRUBEXIF_SUMMARY line
SUMMARY_LINE=$(grep "SCRUBEXIF_SUMMARY" "$LOGFILE" | tail -1)
SCRUBBED=$(echo "$SUMMARY_LINE" | grep -oP 'scrubbed=\K[0-9]+')
SKIPPED=$(echo "$SUMMARY_LINE"  | grep -oP 'skipped=\K[0-9]+')
ERRORS=$(echo "$SUMMARY_LINE"   | grep -oP 'errors=\K[0-9]+')
TOTAL=$(echo "$SUMMARY_LINE"    | grep -oP 'total=\K[0-9]+')

# Check we actually got a summary — if not, docker or scrubexif likely failed
if [[ -z "$TOTAL" ]]; then
    abort "No summary line found — scrubexif may have failed. Check log: $LOGFILE."
fi

if [[ "$ERRORS" -gt 0 || "$SKIPPED" -gt 0 ]]; then
    notify-send -u critical "scrubexif ❌" "Scrubbed $SCRUBBED/$TOTAL files — skipped: $SKIPPED, errors: $ERRORS"
else
    notify-send "scrubexif ✅" "Scrubbed $SCRUBBED/$TOTAL files successfully"
fi
