"""update-yt-dlp.sh: restart only when needed, and never lose a pending restart.

Runs the real script against a stub venv and a stub sudo, so nothing touches
pip, PyPI or systemd.
"""
import os
import shutil
import stat
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "update-yt-dlp.sh"


def _write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Host:
    """A stub backend dir: venv with fake python/pip, PATH with fake sudo."""

    def __init__(self, root: Path, installed: str, available: str):
        self.root = root
        self.script = root / "update-yt-dlp.sh"
        shutil.copy(SCRIPT, self.script)
        self.venv = root / ".venv"
        self.installed = root / "installed-version"
        self.available = root / "available-version"
        self.restarts = root / "restarts.log"
        self.sudo_exit = root / "sudo-exit"
        self.pip_exit = root / "pip-exit"
        self.installed.write_text(installed)
        self.available.write_text(available)
        self.sudo_exit.write_text("0")
        self.pip_exit.write_text("0")
        _write_executable(self.venv / "bin" / "python", f'cat "{self.installed}"\n')
        _write_executable(
            self.venv / "bin" / "pip",
            f'rc=$(cat "{self.pip_exit}"); [ "$rc" = 0 ] || exit "$rc"\n'
            f'cp "{self.available}" "{self.installed}"\n',
        )
        _write_executable(
            root / "stub-bin" / "sudo",
            f'rc=$(cat "{self.sudo_exit}"); [ "$rc" = 0 ] || exit "$rc"\n'
            f'echo "$*" >> "{self.restarts}"\n',
        )

    def run(self, **env) -> subprocess.CompletedProcess:
        full_env = {
            **os.environ,
            "PATH": f"{self.root / 'stub-bin'}{os.pathsep}{os.environ['PATH']}",
            "ARIA_VENV": str(self.venv),
            **env,
        }
        return subprocess.run(
            ["bash", str(self.script)], env=full_env, capture_output=True, text=True
        )

    def restart_count(self) -> int:
        if not self.restarts.exists():
            return 0
        return len(self.restarts.read_text().splitlines())


def test_no_new_version_does_not_restart(tmp_path):
    host = Host(tmp_path, installed="2026.1.1", available="2026.1.1")

    result = host.run()

    assert result.returncode == 0, result.stderr
    assert host.restart_count() == 0


def test_new_version_restarts_once_then_settles(tmp_path):
    host = Host(tmp_path, installed="2026.1.1", available="2026.1.2")

    assert host.run().returncode == 0
    assert host.restarts.read_text().strip() == "systemctl restart aria-backend"

    assert host.run().returncode == 0
    assert host.restart_count() == 1


def test_failed_restart_is_retried_on_next_run(tmp_path):
    host = Host(tmp_path, installed="2026.1.1", available="2026.1.2")
    host.sudo_exit.write_text("1")

    failed = host.run()
    assert failed.returncode != 0
    assert host.restart_count() == 0

    # The upgrade already landed, so this run sees no version change. The
    # backend is still running the old code and must get its restart anyway.
    host.sudo_exit.write_text("0")
    assert host.run().returncode == 0
    assert host.restart_count() == 1

    assert host.run().returncode == 0
    assert host.restart_count() == 1


def test_failed_upgrade_does_not_restart(tmp_path):
    host = Host(tmp_path, installed="2026.1.1", available="2026.1.2")
    host.pip_exit.write_text("1")

    assert host.run().returncode != 0
    assert host.restart_count() == 0


def test_venv_defaults_to_the_one_beside_the_script(tmp_path):
    host = Host(tmp_path, installed="2026.1.1", available="2026.1.2")
    env = {k: v for k, v in os.environ.items() if k != "ARIA_VENV"}
    env["PATH"] = f"{tmp_path / 'stub-bin'}{os.pathsep}{env['PATH']}"

    result = subprocess.run(
        ["bash", str(host.script)], env=env, capture_output=True, text=True
    )

    assert result.returncode == 0, result.stderr
    assert host.installed.read_text() == "2026.1.2"
