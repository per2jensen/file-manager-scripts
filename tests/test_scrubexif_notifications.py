# SPDX-License-Identifier: GPL-3.0-or-later
"""Desktop-notification tests for the Nautilus scrubexif wrapper."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "scrubexif.sh"


def _write_fake_notifier(binary_dir: Path, capture_path: Path) -> None:
    """Create a notify-send executable that records its arguments.

    Args:
        binary_dir: Directory that will be prepended to PATH.
        capture_path: File that receives one argument per line.

    Returns:
        None.

    Raises:
        OSError: If the executable cannot be created.
    """
    notifier_path = binary_dir / "notify-send"
    notifier_path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$@\" > \"${NOTIFY_CAPTURE}\"\n",
        encoding="utf-8",
    )
    notifier_path.chmod(0o755)


def _run_notification(
    tmp_path: Path,
    counts: tuple[int, int, int, int, int, int, int, int, int],
) -> list[str]:
    """Call the real notification function with a fake notifier executable.

    Args:
        tmp_path: Isolated directory for the executable and captured arguments.
        counts: Selected, total, scrubbed, skipped, errors, unsupported,
            examined, duplicate-deleted, and duplicate-moved counts.

    Returns:
        One captured notify-send argument per list item.

    Raises:
        subprocess.CalledProcessError: If the Bash function fails.
        OSError: If test files cannot be created or read.
    """
    binary_dir = tmp_path / "bin"
    binary_dir.mkdir()
    capture_path = tmp_path / "notification.txt"
    _write_fake_notifier(binary_dir, capture_path)

    environment = os.environ.copy()
    environment["PATH"] = f"{binary_dir}:{environment['PATH']}"
    environment["NOTIFY_CAPTURE"] = str(capture_path)
    environment["SCRUBEXIF_LOGFILE"] = str(tmp_path / "scrubexif.log")
    command = [
        "bash",
        "-c",
        'source "$1"; shift; send_summary_notification "$@"',
        "bash",
        str(SCRIPT),
        *(str(value) for value in counts),
    ]
    subprocess.run(command, check=True, env=environment, capture_output=True, text=True)
    return capture_path.read_text(encoding="utf-8").splitlines()


def _run_wrapper(
    tmp_path: Path,
    summary_line: str,
    docker_exit: int,
    selected_file_count: int,
    *,
    filesystem_type: str = "ext4",
    mutate_selected_index: int | None = None,
    mutate_original_index: int | None = None,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run the wrapper with real files and controlled command adapters.

    Args:
        tmp_path: Isolated directory for inputs, logs, and fake executables.
        summary_line: Current invocation summary emitted by fake Docker.
        docker_exit: Exit status returned by fake Docker.
        selected_file_count: Number of real files supplied as selected paths.
        filesystem_type: Filesystem type returned by the fake findmnt command.
        mutate_selected_index: Selected file changed in the mounted directory,
            or None to leave all mounted files unchanged.
        mutate_original_index: Selected original changed while Docker runs, or
            None to leave originals untouched outside the mounted directory.

    Returns:
        Completed wrapper process and captured notification arguments.

    Raises:
        OSError: If test files cannot be created or read.
        ValueError: If an argument is outside its accepted range.
    """
    if docker_exit < 0 or docker_exit > 255:
        raise ValueError("docker_exit must be between zero and 255")
    if selected_file_count < 1:
        raise ValueError("selected_file_count must be positive")
    if not filesystem_type:
        raise ValueError("filesystem_type must not be empty")
    for name, index in (
        ("mutate_selected_index", mutate_selected_index),
        ("mutate_original_index", mutate_original_index),
    ):
        if index is not None and (index < 0 or index >= selected_file_count):
            raise ValueError(
                f"{name} must identify one of the selected files or be None"
            )

    input_dir = tmp_path / "input"
    binary_dir = tmp_path / "bin"
    input_dir.mkdir()
    binary_dir.mkdir()

    selected_paths: list[str] = []
    for index in range(selected_file_count):
        selected_path = input_dir / f"selected-{index}.jpg"
        selected_path.write_bytes(f"original-{index}".encode("utf-8"))
        selected_paths.append(str(selected_path))

    capture_path = tmp_path / "notification.txt"
    _write_fake_notifier(binary_dir, capture_path)
    docker_path = binary_dir / "docker"
    docker_path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"info\" ]]; then exit 0; fi\n"
        "if [[ \"${1:-}\" == \"run\" ]]; then\n"
        "    mount_dir=''\n"
        "    previous=''\n"
        "    for argument in \"$@\"; do\n"
        "        if [[ \"${previous}\" == '-v' ]]; then\n"
        "            mount_dir=\"${argument%:/photos}\"\n"
        "            break\n"
        "        fi\n"
        "        previous=\"${argument}\"\n"
        "    done\n"
        "    [[ -n \"${mount_dir}\" ]] || exit 98\n"
        "    if [[ -n \"${DOCKER_MUTATE_NAME:-}\" ]]; then\n"
        "        printf '%s' 'scrubbed-output' > \"${mount_dir}/${DOCKER_MUTATE_NAME}\"\n"
        "    fi\n"
        "    if [[ -n \"${DOCKER_ORIGINAL_TO_MUTATE:-}\" ]]; then\n"
        "        printf '%s' 'concurrent-change' > \"${DOCKER_ORIGINAL_TO_MUTATE}\"\n"
        "    fi\n"
        "    printf '%s\\n' \"${DOCKER_SUMMARY}\"\n"
        "    exit \"${DOCKER_EXIT}\"\n"
        "fi\n"
        "exit 2\n",
        encoding="utf-8",
    )
    docker_path.chmod(0o755)
    findmnt_path = binary_dir / "findmnt"
    findmnt_path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"${FINDMNT_FSTYPE}\"\n",
        encoding="utf-8",
    )
    findmnt_path.chmod(0o755)

    log_path = tmp_path / "scrubexif.log"
    log_path.write_text(
        "SCRUBEXIF_SUMMARY total=9 scrubbed=9 skipped=0 errors=0 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=0 examined=9 "
        "duration=1.000\n",
        encoding="utf-8",
    )
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{binary_dir}:{environment['PATH']}",
            "NOTIFY_CAPTURE": str(capture_path),
            "DOCKER_SUMMARY": summary_line,
            "DOCKER_EXIT": str(docker_exit),
            "DOCKER_MUTATE_NAME": (
                Path(selected_paths[mutate_selected_index]).name
                if mutate_selected_index is not None
                else ""
            ),
            "DOCKER_ORIGINAL_TO_MUTATE": (
                selected_paths[mutate_original_index]
                if mutate_original_index is not None
                else ""
            ),
            "FINDMNT_FSTYPE": filesystem_type,
            "RUN_AS_UID": "1000",
            "RUN_AS_GID": "1000",
            "SCRUBEXIF_LOGFILE": str(log_path),
            "NAUTILUS_SCRIPT_SELECTED_FILE_PATHS": "\n".join(selected_paths),
        }
    )
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        check=False,
        env=environment,
        capture_output=True,
        text=True,
    )
    arguments = capture_path.read_text(encoding="utf-8").splitlines()
    return result, arguments


def test_notification_success_reports_compact_nonzero_counts(tmp_path: Path) -> None:
    """A successful mixed selection reports only useful counts compactly.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (11, 10, 10, 0, 0, 1, 11, 0, 0))

    assert arguments[:4] == ["-u", "normal", "-i", "emblem-default"]
    assert arguments[4] == "scrubexif ✅ Scrubbing complete"
    assert arguments[5] == "Examined 11/11 • scrubbed 10/10 JPEGs • unsupported 1"
    assert "skipped" not in arguments[5]
    assert "errors" not in arguments[5]
    assert "duplicates" not in arguments[5]


def test_notification_selected_examined_mismatch_is_warning(tmp_path: Path) -> None:
    """A count mismatch prevents an otherwise successful green result.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (3, 2, 2, 0, 0, 0, 2, 0, 0))

    assert arguments[:4] == ["-u", "normal", "-i", "dialog-warning"]
    assert arguments[4] == "scrubexif ⚠️ Completed with warnings"
    assert arguments[5] == "Examined 2/3 • scrubbed 2/2 JPEGs"


def test_notification_skipped_file_is_warning(tmp_path: Path) -> None:
    """A skipped JPEG produces a warning with reconciled counts.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (2, 2, 1, 1, 0, 0, 2, 0, 0))

    assert arguments[:4] == ["-u", "normal", "-i", "dialog-warning"]
    assert arguments[4] == "scrubexif ⚠️ Completed with warnings"
    assert arguments[5] == "Examined 2/2 • scrubbed 1/2 JPEGs • skipped 1"


def test_notification_processing_error_is_critical(tmp_path: Path) -> None:
    """A processing error takes precedence over other classifications.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (1, 1, 0, 0, 1, 0, 1, 0, 0))

    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert arguments[4] == "scrubexif ❌ Completed with errors"
    assert arguments[5] == "Examined 1/1 • scrubbed 0/1 JPEG • errors 1"


def test_notification_duplicate_only_is_informational(tmp_path: Path) -> None:
    """A handled duplicate without new output is a neutral result.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (1, 1, 0, 0, 0, 0, 1, 0, 1))

    assert arguments[:4] == ["-u", "low", "-i", "dialog-information"]
    assert arguments[4] == "scrubexif ℹ️ Duplicates handled"
    assert arguments[5] == "Examined 1/1 • scrubbed 0/1 JPEG • duplicates 1"


def test_wrapper_uses_current_summary_instead_of_stale_log(tmp_path: Path) -> None:
    """The wrapper ignores a successful summary left by an earlier run.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=0 scrubbed=0 skipped=0 errors=0 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=1 examined=1 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(tmp_path, current_summary, 0, 1)

    assert result.returncode == 0, result.stderr
    assert arguments[:4] == ["-u", "low", "-i", "dialog-information"]
    assert arguments[4] == "scrubexif ℹ️ Nothing processed"
    assert "unsupported 1" in arguments[5]


def test_wrapper_preserves_failed_docker_status(tmp_path: Path) -> None:
    """An abnormal Docker failure publishes nothing and preserves its status.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=1 scrubbed=0 skipped=0 errors=1 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=0 examined=1 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(
        tmp_path,
        current_summary,
        7,
        1,
        filesystem_type="fuse.sshfs",
        mutate_selected_index=0,
    )

    assert result.returncode == 7
    assert (tmp_path / "input" / "selected-0.jpg").read_bytes() == b"original-0"
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert arguments[5] == "scrubexif container failed (rc=7); remote originals unchanged"


def test_wrapper_remote_partial_error_publishes_only_changed_output(
    tmp_path: Path,
) -> None:
    """A controlled mixed remote run publishes its successful JPEG.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=2 scrubbed=1 skipped=0 errors=1 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=2 examined=4 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(
        tmp_path,
        current_summary,
        1,
        4,
        filesystem_type="fuse.sshfs",
        mutate_selected_index=0,
    )

    assert result.returncode == 1
    assert (tmp_path / "input" / "selected-0.jpg").read_bytes() == b"scrubbed-output"
    for index in range(1, 4):
        assert (tmp_path / "input" / f"selected-{index}.jpg").read_bytes() == (
            f"original-{index}".encode("utf-8")
        )
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert arguments[4] == "scrubexif ❌ Completed with errors"
    assert arguments[5] == (
        "Examined 4/4 • scrubbed 1/2 JPEGs • errors 1 • unsupported 2"
    )
    assert "Atomically published 1 changed file(s)" in result.stdout


def test_wrapper_remote_concurrent_change_prevents_copy_back(tmp_path: Path) -> None:
    """A changed remote original is never overwritten by a scrubbed copy.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=1 scrubbed=1 skipped=0 errors=0 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=0 examined=1 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(
        tmp_path,
        current_summary,
        0,
        1,
        filesystem_type="nfs4",
        mutate_selected_index=0,
        mutate_original_index=0,
    )

    assert result.returncode == 1
    assert (tmp_path / "input" / "selected-0.jpg").read_bytes() == b"concurrent-change"
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert arguments[5] == "Original changed during processing: selected-0.jpg"


def test_wrapper_rejects_invalid_summary_counter(tmp_path: Path) -> None:
    """A malformed engine summary fails fast with a critical notification.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=invalid scrubbed=0 skipped=0 errors=0 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=0 examined=1 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(
        tmp_path,
        current_summary,
        1,
        1,
        filesystem_type="cifs",
        mutate_selected_index=0,
    )

    assert result.returncode == 1
    assert (tmp_path / "input" / "selected-0.jpg").read_bytes() == b"original-0"
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert "Invalid total count" in arguments[5]


def test_wrapper_rejects_error_exit_without_reported_errors(tmp_path: Path) -> None:
    """Exit status one without summary errors cannot publish remote output.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    current_summary = (
        "SCRUBEXIF_SUMMARY total=1 scrubbed=1 skipped=0 errors=0 "
        "duplicates_deleted=0 duplicates_moved=0 unsupported=0 examined=1 "
        "duration=0.100"
    )
    result, arguments = _run_wrapper(
        tmp_path,
        current_summary,
        1,
        1,
        filesystem_type="smbfs",
        mutate_selected_index=0,
    )

    assert result.returncode == 1
    assert (tmp_path / "input" / "selected-0.jpg").read_bytes() == b"original-0"
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert "exited with rc=1 but reported no errors" in arguments[5]
