"""Session evidence log: one JSON line per command, so a listening verdict can cite values."""

from __future__ import annotations

import json
from pathlib import Path


class JsonlLog:
    """Append-only JSONL. A ``None`` path keeps the console silent (tests, demos)."""

    def __init__(self, path: Path | None):
        self._path = path
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)

    def append(self, record: dict) -> None:
        if self._path is None:
            return
        with open(self._path, "a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=False) + "\n")
