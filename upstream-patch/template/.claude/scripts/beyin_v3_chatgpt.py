"""Optional ChatGPT Web bridge controller. Disabled by default; stores no secrets."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

CONFIG = "chatgpt.json"
DEFAULT_MODE = "off"


def _config_path(state):
    return Path(state) / CONFIG


def _read(state):
    path = _config_path(state)
    if not path.exists():
        return {}
    if path.is_symlink() or path.stat().st_size > 4096:
        raise ValueError("chatgpt_config_invalid")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ValueError("chatgpt_config_invalid") from None
    if not isinstance(data, dict) or set(data) - {"mode", "bridge_root"}:
        raise ValueError("chatgpt_config_invalid")
    mode = data.get("mode", DEFAULT_MODE)
    root = data.get("bridge_root")
    if mode not in ("off", "on"):
        raise ValueError("chatgpt_config_invalid")
    if root is not None and (not isinstance(root, str) or not Path(root).is_absolute()):
        raise ValueError("chatgpt_config_invalid")
    return data


def _write(state, data):
    path = _config_path(state)
    path.parent.mkdir(parents=True, exist_ok=True)
    body = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    fd, name = tempfile.mkstemp(prefix=".chatgpt-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _default_root():
    configured = os.environ.get("AVENOX_BRIDGE_HOME")
    if configured:
        return Path(configured).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local")))
        return base / "avenox-brain-bridge"
    return Path.home() / ".local/share/avenox-brain-bridge"


def _bridge_root(config, supplied=None, required=False):
    value = supplied or config.get("bridge_root")
    root = Path(value).expanduser() if value else _default_root()
    try:
        root = root.resolve()
    except (OSError, RuntimeError):
        if required:
            raise ValueError("chatgpt_bridge_not_installed") from None
        return None
    valid = root.is_dir() and (root / "src/cli.mjs").is_file() and (root / "package.json").is_file()
    if not valid:
        if required:
            raise ValueError("chatgpt_bridge_not_installed")
        return None
    return root


def _node():
    node = shutil.which("node")
    if not node:
        raise ValueError("chatgpt_node_missing")
    try:
        result = subprocess.run([node, "--version"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, encoding="utf-8", timeout=5, check=True)
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\s*", result.stdout)
    except (OSError, subprocess.SubprocessError):
        match = None
    if not match or (int(match.group(1)), int(match.group(2))) < (20, 6):
        raise ValueError("chatgpt_node_too_old")
    return node


def _call(root, action):
    node = _node()
    command = [node]
    env_file = root / ".env"
    if env_file.is_file() and not env_file.is_symlink():
        command.append("--env-file=" + str(env_file))
    command += [str(root / "src/cli.mjs"), action]
    try:
        result = subprocess.run(command, cwd=root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("chatgpt_bridge_unavailable") from None
    if result.returncode:
        raise ValueError("chatgpt_bridge_command_failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError("chatgpt_bridge_invalid_output") from None
    if not isinstance(payload, dict):
        raise ValueError("chatgpt_bridge_invalid_output")
    return payload


def status(state):
    config = _read(state)
    mode = config.get("mode", DEFAULT_MODE)
    root = _bridge_root(config)

    # Match Jev's default-off contract: a never-enabled or saved-off integration
    # does not launch Node just because doctor/status was requested.
    if mode == "off":
        return {"mode": "off", "configured": bool(config.get("bridge_root")),
                "available": root is not None, "running": False}

    if root is None:
        return {"mode": "on", "configured": bool(config.get("bridge_root")),
                "available": False, "running": False, "error": "bridge_not_found"}
    try:
        worker = _call(root, "status")
        running = worker.get("running") is True
        result = {"mode": "on", "configured": True, "available": True, "running": running}
        if isinstance(worker.get("pid"), int):
            result["pid"] = worker["pid"]
        return result
    except ValueError as exc:
        return {"mode": "on", "configured": True, "available": False,
                "running": False, "error": str(exc)}


def set_mode(state, mode, bridge_root=None):
    if mode not in ("off", "on"):
        raise ValueError("chatgpt_mode_invalid")
    config = _read(state)
    if mode == "on":
        root = _bridge_root(config, bridge_root, required=True)
        worker = _call(root, "start")
        if worker.get("running") is not True:
            raise ValueError("chatgpt_bridge_start_failed")
        _write(state, {"mode": "on", "bridge_root": str(root)})
        return {"mode": "on", "configured": True, "available": True,
                "running": True, **({"pid": worker["pid"]} if isinstance(worker.get("pid"), int) else {})}

    root = _bridge_root(config)
    if config.get("mode") == "on":
        if root is None:
            raise ValueError("chatgpt_bridge_unavailable")
        _call(root, "stop")
    saved = {"mode": "off"}
    if root is not None:
        saved["bridge_root"] = str(root)
    elif isinstance(config.get("bridge_root"), str):
        saved["bridge_root"] = config["bridge_root"]
    _write(state, saved)
    return {"mode": "off", "configured": bool(saved.get("bridge_root")),
            "available": root is not None, "running": False}
