#!/usr/bin/env python3
"""Idempotently register a vault path in Obsidian's config.

Reads env: OBS_CFG (path to obsidian.json), VAULT (absolute vault dir).
Adds an entry only if no vault with that path exists. Writes atomically so a
concurrent Obsidian process can't observe a half-written file. Registers with
"open": false so we never hijack Obsidian's own startup — intentional opens are
handled separately via an `obsidian://open` deep link. Never raises to the caller.
"""
import json
import os
import secrets
import sys
import time


def main() -> int:
    cfg = os.environ.get("OBS_CFG", "")
    target = os.environ.get("VAULT", "")
    if not cfg or not target or not os.path.exists(cfg):
        return 0
    try:
        with open(cfg) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict):
        return 0
    vaults = data.setdefault("vaults", {})
    if not isinstance(vaults, dict):
        return 0
    if any(isinstance(v, dict) and v.get("path") == target for v in vaults.values()):
        return 0  # already registered — nothing to do
    vid = secrets.token_hex(8)
    vaults[vid] = {"path": target, "ts": int(time.time() * 1000), "open": False}
    tmp = cfg + ".plan-vault.tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, cfg)  # atomic
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return 0
    print("registered %s -> %s" % (vid, target))
    return 0


if __name__ == "__main__":
    sys.exit(main())
