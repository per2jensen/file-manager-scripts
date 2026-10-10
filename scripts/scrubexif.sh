#!/usr/bin/env bash
# License
# All scripts are licensed under the
# GNU Public License v3.0 or later.
# See license details here: https://www.gnu.org/licenses/gpl-3.0.html
#
# Nautilus helper script — strips EXIF metadata from selected JPEG files
# using the scrubexif Docker container (https://github.com/per2jensen/scrubexif).
#
# USAGE
#   Select one or more files in Nautilus, then run this script via the Scripts
#   menu. At least one file must be selected — without a selection, scrubexif
#   would process the entire directory, which is irreversible.
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
#       - All selected files are copied to a fresh local temp directory.
#       - Docker processes them all in a single container run.
#       - Processed files are copied back to the original directory.
#       - Temporary resources are removed when the script exits.
#
#   4. Result: a desktop notification classifies the outcome and reports the
#      selected, examined, scrubbed, skipped, error, duplicate, and unsupported
#      counts. A full log is written to /tmp/scrubexif.log by default.

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

cleanup() {
    local workdir="${1:-}"
    local run_log="${2:-}"

    if [[ -n "${run_log}" && -f "${run_log}" ]]; then
        rm -f -- "${run_log}"
    fi
    if [[ -n "${workdir}" && -d "${workdir}" ]]; then
        rm -rf -- "${workdir}"
    fi
}

configure_cleanup_trap() {
    local workdir="${1:-}"
    local run_log="${2:-}"
    local cleanup_command=""

    # %q safely preserves temporary paths in the deferred EXIT command.
    printf -v cleanup_command 'cleanup %q %q' "${workdir}" "${run_log}"
    # Expand now because workdir and run_log are local to main and may be out
    # of scope when Bash executes the EXIT trap.
    # shellcheck disable=SC2064
    trap "${cleanup_command}" EXIT
}

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
    local summary_line="${1:-}"
    local key="${2:-}"

    if [[ -z "${summary_line}" || -z "${key}" ]]; then
        return 1
    fi

    printf '%s\n' "${summary_line}" | awk -v wanted="${key}" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ ("^" wanted "=")) {
                    split($i, value, "=")
                    print value[2]
                    exit
                }
            }
        }
    '
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
    body="Selected ${selected} files — examined: ${examined}; scrubbed: ${scrubbed}/${total} JPEGs; skipped: ${skipped}; errors: ${errors}; duplicates: ${duplicates_handled}; unsupported: ${unsupported}"

    if ((errors > 0)); then
        send_notification critical dialog-error "scrubexif ❌ Completed with errors" "${body}"
        return
    fi

    if ((skipped > 0 || selected != examined)); then
        if ((selected != examined)); then
            body+="; selected/examined mismatch"
        fi
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
    local -a args=()
    local -a basenames=()
    local file=""
    local file_dir=""
    local fstype=""
    local needs_copy=false
    local total_bytes=0
    local available_bytes=0
    local needed_mb=0
    local available_mb=0
    local workdir=""
    local mount_dir=""
    local run_log=""
    local run_as_uid="${RUN_AS_UID:-$(id -u)}"
    local run_as_gid="${RUN_AS_GID:-$(id -g)}"
    local -a pipeline_status=()
    local docker_status=0
    local tee_status=0
    local summary_line=""
    local total=""
    local scrubbed=""
    local skipped=""
    local errors=""
    local unsupported=""
    local examined=""
    local duplicates_deleted=""
    local duplicates_moved=""

    configure_cleanup_trap "${workdir}" "${run_log}"
    rotate_log_if_needed
    log "===>>> $(date --iso-8601=seconds) - running $0"

    command -v docker &>/dev/null || abort "docker is not installed or not in PATH"
    docker info &>/dev/null || abort "docker daemon is not running or current user cannot reach it"

    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue
        args+=("${file}")
    done <<< "${selected_paths}"

    if ((${#args[@]} == 0)); then
        abort "No files selected — aborting to avoid scrubbing entire directory"
    fi

    for file in "${args[@]}"; do
        [[ -f "${file}" ]] || abort "File not found: ${file}"
    done

    file_dir="$(dirname "${args[0]}")"
    for file in "${args[@]}"; do
        if [[ "$(dirname "${file}")" != "${file_dir}" ]]; then
            abort "Files must all be in the same directory — found files in multiple directories"
        fi
    done

    for file in "${args[@]}"; do
        basenames+=("$(basename "${file}")")
    done

    log "Processing ${#basenames[@]} file(s) in ${file_dir}"

    fstype="$(findmnt -n -o FSTYPE --target "${file_dir}" 2>/dev/null || printf 'unknown\n')"
    if [[ "${fstype}" == fuse* || "${fstype}" == nfs* || "${fstype}" == cifs || "${fstype}" == smbfs ]]; then
        needs_copy=true
        for file in "${args[@]}"; do
            total_bytes=$((total_bytes + $(stat -c%s "${file}")))
        done
        available_bytes="$(df --output=avail -B1 "${TMPDIR:-/tmp}" | tail -1 | tr -d ' ')"
        if ((total_bytes >= available_bytes)); then
            needed_mb=$((total_bytes / 1024 / 1024))
            available_mb=$((available_bytes / 1024 / 1024))
            abort "Not enough temp space to copy files: need ${needed_mb}MB, only ${available_mb}MB free in ${TMPDIR:-/tmp}"
        fi

        workdir="$(mktemp -d)"
        configure_cleanup_trap "${workdir}" "${run_log}"
        log "Filesystem type '${fstype}' detected — copying files to local temp dir: ${workdir}"
        for file in "${basenames[@]}"; do
            cp -- "${file_dir}/${file}" "${workdir}/"
        done
        mount_dir="${workdir}"
    else
        mount_dir="${file_dir}"
    fi

    validate_count RUN_AS_UID "${run_as_uid}"
    validate_count RUN_AS_GID "${run_as_gid}"
    if ((run_as_uid == 0)); then
        abort "Running as root is not allowed"
    fi
    log "Running docker as UID:GID ${run_as_uid}:${run_as_gid}"

    run_log="$(mktemp --tmpdir scrubexif-run.XXXXXX)"
    configure_cleanup_trap "${workdir}" "${run_log}"

    set +e
    docker run --rm \
        --user "${run_as_uid}:${run_as_gid}" \
        --read-only --security-opt no-new-privileges \
        --tmpfs /tmp \
        -v "${mount_dir}:/photos" \
        per2jensen/scrubexif:latest --clean-inline "${basenames[@]}" \
        2>&1 | tee -a "${LOGFILE}" "${run_log}"
    pipeline_status=("${PIPESTATUS[@]}")
    docker_status="${pipeline_status[0]}"
    tee_status="${pipeline_status[1]}"
    set -e

    if ((tee_status != 0)); then
        abort "Unable to capture scrubexif output. Check log: ${LOGFILE}"
    fi

    if [[ "${needs_copy}" == true && ${docker_status} -eq 0 ]]; then
        log "Copying processed files back to ${file_dir}"
        for file in "${basenames[@]}"; do
            cp -- "${workdir}/${file}" "${file_dir}/${file}" || abort "Failed to copy processed file back: ${file}"
        done
    fi

    summary_line="$(awk '/^SCRUBEXIF_SUMMARY / { line=$0 } END { print line }' "${run_log}")"
    [[ -n "${summary_line}" ]] || abort "No summary line found — scrubexif may have failed. Check log: ${LOGFILE}"

    total="$(summary_value "${summary_line}" total)"
    scrubbed="$(summary_value "${summary_line}" scrubbed)"
    skipped="$(summary_value "${summary_line}" skipped)"
    errors="$(summary_value "${summary_line}" errors)"
    duplicates_deleted="$(summary_value "${summary_line}" duplicates_deleted)"
    duplicates_moved="$(summary_value "${summary_line}" duplicates_moved)"
    unsupported="$(summary_value "${summary_line}" unsupported)"
    examined="$(summary_value "${summary_line}" examined)"

    # Older container summaries lack these two fields. The fallback keeps the
    # wrapper usable while making any hidden unsupported files a visible count
    # mismatch against the Nautilus selection.
    unsupported="${unsupported:-0}"
    validate_count total "${total}"
    validate_count scrubbed "${scrubbed}"
    validate_count skipped "${skipped}"
    validate_count errors "${errors}"
    validate_count duplicates_deleted "${duplicates_deleted}"
    validate_count duplicates_moved "${duplicates_moved}"
    validate_count unsupported "${unsupported}"
    examined="${examined:-$((total + unsupported))}"
    validate_count examined "${examined}"

    send_summary_notification \
        "${#args[@]}" "${total}" "${scrubbed}" "${skipped}" \
        "${errors}" "${unsupported}" "${examined}" \
        "${duplicates_deleted}" "${duplicates_moved}"

    if ((docker_status != 0)); then
        exit "${docker_status}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
