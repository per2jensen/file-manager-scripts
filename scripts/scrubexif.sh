#!/usr/bin/env bash
# License
# All scripts are licensed under the
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html
#
# Nautilus integration for scrubexif (JPEG only).
# https://github.com/per2jensen/scrubexif
#
# HARDENING / CHANGES (2026-10):
# - Refuses empty selection, symlinks, non-regular files, mixed directories,
#   duplicate paths, and root execution. Nautilus supplies newline-delimited
#   selections; filenames containing newlines are unsupported.
# - Container runs without networking or Linux capabilities, with no-new-
#   privileges, read-only rootfs, private size-limited /tmp and process limit.
# - Explicitly validates exactly one machine summary and required numeric fields.
#   Exit status 1 is accepted only with reported processing errors, allowing
#   successful remote outputs from a mixed batch to be published safely.
# - NFS/CIFS/FUSE mode copies inputs to a private local directory. Originals are
#   fingerprinted first; changed originals are NOT overwritten on copy-back.
# - Remote copy-back stages each changed JPEG beside its original, verifies its
#   bytes, then atomically renames it. Never streams directly over an original.
#   Per-file replacement is atomic, but the whole batch is NOT a transaction.
# - Temporary files are cleaned on normal exit and handled INT/TERM. An abrupt
#   power loss or SIGKILL may leave a .scrubexif-stage.* file beside originals;
#   do not delete such a file without inspecting it.
# - Success is based on both subprocess status and validated summary.
#
# SECURITY BOUNDARIES:
# - The selected directory is mounted read/write in local clean-inline mode;
#   a compromised image parser could access other files in that directory.
# - --network=none prevents ordinary network use, but not all host interactions.
# - For remote copy-back, concurrent writers must be externally serialized.
#   The pre-replace check narrows races but cannot make them impossible.
# - Test with copies of JPEGs before using on irreplaceable originals.
#
# Environment: SCRUBEXIF_IMAGE (default per2jensen/scrubexif:latest),
# RUN_AS_UID, RUN_AS_GID, SCRUBEXIF_LOGFILE, TMPDIR.
# Requires: docker, findmnt, sha256sum, cmp, sync (coreutils), notify-send.
#
set -euo pipefail

LOGFILE="${SCRUBEXIF_LOGFILE:-/tmp/scrubexif.log}"
MAX_LOG=102400
HALF_LOG=51200

log() {
    printf '%s\n' "$*" | tee -a "${LOGFILE}"
}

log_error() {
    local message="${1:-Unknown failure}"

    if ! printf '%s\n' "${message}" | tee -a "${LOGFILE}" >&2; then
        >&2 echo "ERROR: unable to append diagnostics to ${LOGFILE}"
    fi
}

send_notification() {
    local urgency="${1:-}"
    local icon="${2:-}"
    local title="${3:-}"
    local body="${4:-}"

    if [[ -z "${urgency}" || -z "${icon}" || -z "${title}" || -z "${body}" ]]; then
        log_error "$0: ERROR: invalid desktop notification parameters"
        return 1
    fi

    if ! notify-send -u "${urgency}" -i "${icon}" "${title}" "${body}"; then
        log_error "$0: WARNING: desktop notification failed: ${title}"
    fi
}

abort() {
    local message="${1:-Unknown failure}"

    log_error "$0: ERROR: ${message}"
    send_notification critical dialog-error "scrubexif ❌" "${message}"
    exit 1
}

WORKDIR=""
RUN_LOG=""
declare -a STAGING_FILES=()
cleanup() {
    local f
    for f in "${STAGING_FILES[@]}"; do
        [[ -z "$f" ]] || rm -f -- "$f" || true
    done
    [[ -z "$RUN_LOG" ]] || rm -f -- "$RUN_LOG" || true
    [[ -z "$WORKDIR" ]] || rm -rf -- "$WORKDIR" || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rotate_log_if_needed() {
    local rotated_log=""

    if [[ ! -f "${LOGFILE}" ]] || (( $(stat -c%s "${LOGFILE}") <= MAX_LOG )); then
        return
    fi

    rotated_log="$(mktemp --tmpdir="$(dirname "${LOGFILE}")" scrubexif-log.XXXXXX)"
    if ! tail -c "${HALF_LOG}" "${LOGFILE}" | tail -n +2 > "${rotated_log}"; then
        rm -f -- "${rotated_log}"
        abort "Unable to rotate log: ${LOGFILE}"
    fi
    mv -- "${rotated_log}" "${LOGFILE}"
}

summary_value() {
    local line="$1" key="$2"
    # Missing or repeated keys are errors, rather than silently taking one.
    awk -v wanted="$key" '{
        n=0
        for(i=2;i<=NF;i++) {
            split($i,a,"=")
            if (a[1]==wanted) {n++; v=a[2]}
        }
        if(n!=1) exit 1
        print v
    }' <<< "$line"
}

validate_count() {
    local name="${1:-}"
    local value="${2:-}"

    if [[ -z "${name}" || ! "${value}" =~ ^[0-9]+$ ]]; then
        abort "Invalid ${name} count in scrubexif summary: '${value}'"
    fi
}

send_summary_notification() {
    local selected="${1:-}"
    local total="${2:-}"
    local scrubbed="${3:-}"
    local skipped="${4:-}"
    local errors="${5:-}"
    local unsupported="${6:-}"
    local examined="${7:-}"
    local duplicates_deleted="${8:-}"
    local duplicates_moved="${9:-}"
    local duplicates_handled=0
    local body=""
    local jpeg_noun="JPEGs"

    validate_count selected "${selected}"
    validate_count total "${total}"
    validate_count scrubbed "${scrubbed}"
    validate_count skipped "${skipped}"
    validate_count errors "${errors}"
    validate_count unsupported "${unsupported}"
    validate_count examined "${examined}"
    validate_count duplicates_deleted "${duplicates_deleted}"
    validate_count duplicates_moved "${duplicates_moved}"

    duplicates_handled=$((duplicates_deleted + duplicates_moved))
    if ((total == 1)); then
        jpeg_noun="JPEG"
    fi

    body="Examined ${examined}/${selected} • scrubbed ${scrubbed}/${total} ${jpeg_noun}"
    if ((skipped > 0)); then
        body+=" • skipped ${skipped}"
    fi
    if ((errors > 0)); then
        body+=" • errors ${errors}"
    fi
    if ((duplicates_handled > 0)); then
        body+=" • duplicates ${duplicates_handled}"
    fi
    if ((unsupported > 0)); then
        body+=" • unsupported ${unsupported}"
    fi

    if ((errors > 0)); then
        send_notification critical dialog-error "scrubexif ❌ Completed with errors" "${body}"
        return
    fi

    if ((skipped > 0 || selected != examined)); then
        send_notification normal dialog-warning "scrubexif ⚠️ Completed with warnings" "${body}"
        return
    fi

    if ((total == 0)); then
        send_notification low dialog-information "scrubexif ℹ️ Nothing processed" "${body}"
        return
    fi

    if ((scrubbed == 0 && duplicates_handled > 0)); then
        send_notification low dialog-information "scrubexif ℹ️ Duplicates handled" "${body}"
        return
    fi

    if ((scrubbed == 0)); then
        send_notification low dialog-information "scrubexif ℹ️ Nothing changed" "${body}"
        return
    fi

    send_notification normal emblem-default "scrubexif ✅ Scrubbing complete" "${body}"
}

main() {
    local selected_paths="${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}"
    local -a args=() basenames=() hashes=() changed=() staged=()
    local file file_dir name canonical_dir fstype needs_copy=false
    local total_bytes=0 available_bytes run_as_uid="${RUN_AS_UID:-$(id -u)}"
    local run_as_gid="${RUN_AS_GID:-$(id -g)}"
    local mount_dir docker_status tee_status summary_line
    local total scrubbed skipped errors unsupported examined duplicates_deleted duplicates_moved
    local image="${SCRUBEXIF_IMAGE:-per2jensen/scrubexif:latest}"
    local -a pipeline_status=()
    local expected actual tmp src dst i
    local -A seen=()

    rotate_log_if_needed
    log "===>>> $(date --iso-8601=seconds) - running $0"
    command -v docker >/dev/null || abort "docker is not installed"
    command -v findmnt >/dev/null || abort "findmnt is not installed"
    command -v sha256sum >/dev/null || abort "sha256sum is not installed"
    command -v sync >/dev/null || abort "sync is not installed"
    docker info >/dev/null 2>&1 || abort "Docker daemon unavailable"
    validate_count RUN_AS_UID "$run_as_uid"
    validate_count RUN_AS_GID "$run_as_gid"
    [[ "$run_as_uid" != 0 && "$run_as_uid" != 00 ]] || abort "Running as root is not allowed"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        args+=("$file")
    done <<< "$selected_paths"
    ((${#args[@]} > 0)) || abort "No files selected; refusing to process an entire directory"

    for file in "${args[@]}"; do
        [[ ! -L "$file" && -f "$file" ]] || abort "Not a regular, non-symlink file: $file"
        [[ -z "${seen[$file]+present}" ]] || abort "Repeated selected file: $file"
        seen["$file"]=1
    done
    file_dir="$(dirname -- "${args[0]}")"
    canonical_dir="$(realpath -e -- "$file_dir")" || abort "Cannot resolve source directory"
    for file in "${args[@]}"; do
        [[ "$(realpath -e -- "$(dirname -- "$file")")" == "$canonical_dir" ]] || abort "Selected files must share one directory"
        name="$(basename -- "$file")"
        [[ "$name" != *$'\n'* ]] || abort "Newlines in filenames are unsupported"
        basenames+=("$name")
    done
    # Resolve the source directory once, preserving the safe basenames.
    file_dir="$canonical_dir"
    log "Processing ${#basenames[@]} selected files in $file_dir"
    fstype="$(findmnt -n -o FSTYPE --target "$file_dir")" || abort "Unable to determine filesystem type"
    if [[ "$fstype" == fuse* || "$fstype" == nfs* || "$fstype" == cifs || "$fstype" == smbfs ]]; then
        needs_copy=true
        for name in "${basenames[@]}"; do
            file="$file_dir/$name"
            total_bytes=$((total_bytes + $(stat -c%s -- "$file")))
            hashes+=("$(sha256sum -- "$file" | cut -d ' ' -f 1)")
        done
        available_bytes="$(df --output=avail -B1 "${TMPDIR:-/tmp}" | tail -1 | tr -d ' ')"
        [[ "$available_bytes" =~ ^[0-9]+$ ]] || abort "Cannot determine temporary free space"
        (( total_bytes * 2 < available_bytes )) || abort "Insufficient temporary space (need > 2x selected input size)"
        WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/scrubexif-nautilus.XXXXXXXX")" || abort "Cannot create temporary directory"
        chmod 700 "$WORKDIR"
        log "Filesystem '$fstype': processing local copies in $WORKDIR"
        for name in "${basenames[@]}"; do
            cp -- "$file_dir/$name" "$WORKDIR/$name" || abort "Copy to local temporary directory failed: $name"
        done
        mount_dir="$WORKDIR"
    else
        mount_dir="$file_dir"
    fi

    RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/scrubexif-run.XXXXXXXX")"
    # Capture PIPESTATUS immediately; set +e is required for deliberate failure handling.
    set +e
    docker run --rm \
        --user "${run_as_uid}:${run_as_gid}" \
        --read-only --security-opt no-new-privileges \
        --cap-drop=ALL --network=none --pids-limit=128 \
        --tmpfs /tmp:rw,nosuid,nodev,size=256m,mode=1777 \
        -v "${mount_dir}:/photos" \
        "$image" --clean-inline "${basenames[@]}" \
        2>&1 | tee -a "$LOGFILE" "$RUN_LOG"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    docker_status="${pipeline_status[0]}"
    tee_status="${pipeline_status[1]}"
    ((tee_status == 0)) || abort "Failed to capture scrubexif log output"
    if ((docker_status != 0 && docker_status != 1)); then
        if [[ "$needs_copy" == true ]]; then
            log_error "$0: ERROR: scrubexif container failed (rc=$docker_status); remote originals unchanged"
            send_notification critical dialog-error "scrubexif ❌" \
                "scrubexif container failed (rc=$docker_status); remote originals unchanged"
        else
            log_error "$0: ERROR: scrubexif container failed (rc=$docker_status); local files may already have changed"
            send_notification critical dialog-error "scrubexif ❌" \
                "scrubexif container failed (rc=$docker_status); local files may already have changed"
        fi
        exit "$docker_status"
    fi

    # Require exactly one summary. No publication to a remote filesystem until
    # accounting is checked; local mode relies on scrubexif's own publication.
    local -a summary_lines=()
    mapfile -t summary_lines < <(grep '^SCRUBEXIF_SUMMARY ' "$RUN_LOG" || true)
    ((${#summary_lines[@]} == 1)) || abort "Expected exactly one SCRUBEXIF_SUMMARY, got ${#summary_lines[@]}"
    summary_line="${summary_lines[0]}"
    [[ "$summary_line" == SCRUBEXIF_SUMMARY\ * ]] || abort "Invalid summary prefix"
    total="$(summary_value "$summary_line" total)" || abort "Missing/duplicated total field"
    scrubbed="$(summary_value "$summary_line" scrubbed)" || abort "Missing/duplicated scrubbed field"
    skipped="$(summary_value "$summary_line" skipped)" || abort "Missing/duplicated skipped field"
    errors="$(summary_value "$summary_line" errors)" || abort "Missing/duplicated errors field"
    duplicates_deleted="$(summary_value "$summary_line" duplicates_deleted)" || abort "Missing/duplicated duplicates_deleted field"
    duplicates_moved="$(summary_value "$summary_line" duplicates_moved)" || abort "Missing/duplicated duplicates_moved field"
    # Backward compatibility with older 0.7.x summaries.
    if [[ " $summary_line " == *" unsupported="* ]]; then
        unsupported="$(summary_value "$summary_line" unsupported)" || abort "Duplicated unsupported field"
    else
        unsupported=0
    fi
    if [[ " $summary_line " == *" examined="* ]]; then
        examined="$(summary_value "$summary_line" examined)" || abort "Duplicated examined field"
    else
        examined=$((total + unsupported))
    fi
    for file in total scrubbed skipped errors duplicates_deleted duplicates_moved unsupported examined; do
        validate_count "$file" "${!file}"
    done
    ((examined == ${#args[@]})) || abort "Examined $examined inputs, selected ${#args[@]}; refusing remote copy-back"
    ((total + unsupported == examined)) || abort "Inconsistent summary: total plus unsupported does not equal examined"
    ((scrubbed + skipped + duplicates_deleted + duplicates_moved <= examined)) || abort "Inconsistent summary counters"
    if ((docker_status == 0 && errors != 0)); then
        abort "Inconsistent result: scrubexif exited successfully but reported $errors errors"
    fi
    if ((docker_status == 1 && errors == 0)); then
        abort "Inconsistent result: scrubexif exited with rc=1 but reported no errors"
    fi

    if [[ "$needs_copy" == true ]]; then
        # Prepare ALL changed files before replacing ANY. Ordinary copy failure
        # therefore leaves every original untouched. A rename failure may leave
        # a partially committed batch (previous files replaced atomically).
        for i in "${!basenames[@]}"; do
            name="${basenames[i]}"
            src="$WORKDIR/$name"
            dst="$file_dir/$name"
            [[ -f "$src" && ! -L "$src" && -f "$dst" && ! -L "$dst" ]] || abort "File missing or became unsafe: $name"
            expected="${hashes[i]}"
            actual="$(sha256sum -- "$dst" | cut -d ' ' -f 1)"
            [[ "$expected" == "$actual" ]] || abort "Original changed during processing: $name"
            if cmp -s -- "$src" "$dst"; then
                continue
            fi
            tmp="$(mktemp "$file_dir/.scrubexif-stage.XXXXXXXX")" || abort "Cannot stage output beside $name"
            STAGING_FILES+=("$tmp")
            cp -- "$src" "$tmp" || abort "Failed staging: $name"
            cmp -s -- "$src" "$tmp" || abort "Staged data verification failed: $name"
            chmod --reference="$dst" "$tmp" || abort "Cannot preserve permissions for $name"
            sync -f "$tmp" || abort "Cannot sync staged data: $name"
            changed+=("$i")
            staged+=("$tmp")
        done
        for i in "${!changed[@]}"; do
            name="${basenames[${changed[i]}]}"
            dst="$file_dir/$name"
            [[ -f "$dst" && ! -L "$dst" ]] || abort "Original disappeared before publication: $name"
            actual="$(sha256sum -- "$dst" | cut -d ' ' -f 1)"
            [[ "$actual" == "${hashes[${changed[i]}]}" ]] || abort "Original changed before publication: $name"
            mv -fT -- "${staged[i]}" "$dst" || abort "Atomic replacement failed: $name"
            # Best-effort directory sync; failure is reported rather than hidden.
            sync -f "$file_dir" || abort "Directory sync failed after replacing $name"
        done
        log "Atomically published ${#changed[@]} changed file(s) on '$fstype'"
    fi

    send_summary_notification \
        "${#args[@]}" "$total" "$scrubbed" "$skipped" "$errors" \
        "$unsupported" "$examined" "$duplicates_deleted" "$duplicates_moved"
    return "$docker_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
