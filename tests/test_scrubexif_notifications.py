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
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run the wrapper with real files and controlled command adapters.

    Args:
        tmp_path: Isolated directory for inputs, logs, and fake executables.
        summary_line: Current invocation summary emitted by fake Docker.
        docker_exit: Exit status returned by fake Docker.
        selected_file_count: Number of real files supplied as selected paths.

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

    input_dir = tmp_path / "input"
    binary_dir = tmp_path / "bin"
    input_dir.mkdir()
    binary_dir.mkdir()

    selected_paths: list[str] = []
    for index in range(selected_file_count):
        selected_path = input_dir / f"selected-{index}.jpg"
        selected_path.write_bytes(b"test")
        selected_paths.append(str(selected_path))

    capture_path = tmp_path / "notification.txt"
    _write_fake_notifier(binary_dir, capture_path)
    docker_path = binary_dir / "docker"
    docker_path.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"info\" ]]; then exit 0; fi\n"
        "if [[ \"${1:-}\" == \"run\" ]]; then\n"
        "    printf '%s\\n' \"${DOCKER_SUMMARY}\"\n"
        "    exit \"${DOCKER_EXIT}\"\n"
        "fi\n"
        "exit 2\n",
        encoding="utf-8",
    )
    docker_path.chmod(0o755)

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
            "RUN_AS_UID": "1000",
            "RUN_AS_GID": "1000",
            "SCRUBEXIF_LOGFILE": str(log_path),
            "NAUTILUS_SCRIPT_SELECTED_FILE_PATHS": "\n".join(selected_paths),
        }
    )
    result = subprocess.run(
        [str(SCRIPT)],
        check=False,
        env=environment,
        capture_output=True,
        text=True,
    )
    arguments = capture_path.read_text(encoding="utf-8").splitlines()
    return result, arguments


def test_notification_success_reports_all_reconciliation_counts(tmp_path: Path) -> None:
    """A successful mixed selection reports every count and a success icon.

    Args:
        tmp_path: Isolated test directory.

    Returns:
        None.
    """
    arguments = _run_notification(tmp_path, (11, 10, 10, 0, 0, 1, 11, 0, 0))

    assert arguments[:4] == ["-u", "normal", "-i", "emblem-default"]
    assert arguments[4] == "scrubexif ✅ Scrubbing complete"
    assert arguments[5] == (
        "Selected 11 files — examined: 11; scrubbed: 10/10 JPEGs; "
        "skipped: 0; errors: 0; duplicates: 0; unsupported: 1"
    )


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
    assert arguments[5].endswith("selected/examined mismatch")


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
    assert "skipped: 1" in arguments[5]


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
    assert "errors: 1" in arguments[5]


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
    assert "duplicates: 1" in arguments[5]


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
    assert "unsupported: 1" in arguments[5]


def test_wrapper_preserves_failed_docker_status(tmp_path: Path) -> None:
    """An error notification does not hide Docker's failure status.

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
    result, arguments = _run_wrapper(tmp_path, current_summary, 7, 1)

    assert result.returncode == 7
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert "errors: 1" in arguments[5]


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
    result, arguments = _run_wrapper(tmp_path, current_summary, 0, 1)

    assert result.returncode == 1
    assert arguments[:4] == ["-u", "critical", "-i", "dialog-error"]
    assert "Invalid total count" in arguments[5]
