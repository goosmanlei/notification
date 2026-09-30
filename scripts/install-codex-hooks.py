#!/usr/bin/env python3
"""Merge notification-only hooks; preserve unrelated hooks and never change hook trust."""
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile

DESCRIPTION = "Notification multi-display reminders"

def merge(document, command, remove=False):
    if not isinstance(document, dict) or not isinstance(document.get("hooks", {}), dict):
        raise ValueError("hooks.json must contain an object with a hooks object")
    hooks = document.setdefault("hooks", {})
    groups = {
        "PermissionRequest": "*",
        "PreToolUse": r"(^|\.)request_user_input(_async)?$",
        "PostToolUse": "*",
        "Stop": None,
        "Interrupt": None,
        "SessionEnd": None,
        "UserPromptSubmit": None,
    }
    for event, matcher in groups.items():
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            raise ValueError(f"{event} must be an array")
        kept = []
        for group in entries:
            # Only remove this exact install's commands; don't touch other tools or app locations.
            copy = dict(group)
            copy["hooks"] = [h for h in group.get("hooks", []) if not (
                h.get("command") == command and h.get("statusMessage") == DESCRIPTION)]
            if copy["hooks"]:
                kept.append(copy)
        if not remove:
            group = {"hooks": [{"type": "command", "command": command,
                                "timeout": 3, "statusMessage": DESCRIPTION}]}
            if matcher is not None:
                group["matcher"] = matcher
            kept.append(group)
        hooks[event] = kept
    return document

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Notification.app"))
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    executable = args.app.expanduser().resolve() / "Contents/MacOS/Notification"
    if not args.remove and not executable.is_file():
        parser.error(f"Build/install the app first: {executable}")
    command = shlex.quote(str(executable)) + " --codex-hook"
    path = args.codex_home.expanduser() / "hooks.json"
    previous = path.read_bytes() if path.exists() else None
    document = json.loads(previous) if previous else {}
    merged = merge(document, command, args.remove)
    updated = (json.dumps(merged, indent=2, ensure_ascii=False) + "\n").encode()
    if args.dry_run:
        print(updated.decode(), end="")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if (path.read_bytes() if path.exists() else None) != previous:
        raise SystemExit("hooks.json changed while preparing the merge; run again")
    if updated != previous:
        fd, temp = tempfile.mkstemp(prefix=".notification-hooks-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(updated)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp): os.unlink(temp)
    # Read back the actual file; never mark hooks trusted programmatically.
    if json.loads(path.read_bytes()) != merged:
        raise SystemExit("hooks.json read-back mismatch")
    print(f"{'Removed' if args.remove else 'Installed'} notification hooks: {path}")
    if not args.remove:
        print("In Codex CLI, use /hooks to review and trust the configured hooks.")

if __name__ == "__main__":
    main()
