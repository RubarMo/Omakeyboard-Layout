#!/usr/bin/env python3
"""Persist a keyboard layout list to the user's Hyprland input override.

Rewrites the active kb_layout/kb_variant lines in ~/.config/hypr/input.lua,
then reloads Hyprland and verifies the seat took the new list. Refuses to
write anything unless the file already carries one active kb_layout line:
without it there is no safe anchor, and the stock Omarchy defaults (or the
keyboard-layouts file) own the seat instead.

Usage: layouts-apply.py set <layouts-csv> <variants-csv>
"""

import re
import subprocess
import sys
from pathlib import Path


def run(args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def fail(message):
    print(f"keyboard-switcher: {message}", file=sys.stderr)
    raise SystemExit(1)


CODE = re.compile(r"^[a-z0-9_-]+$")


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "set":
        fail("usage: layouts-apply.py set <layouts-csv> <variants-csv>")
    layouts = sys.argv[2].split(",")
    variants = sys.argv[3].split(",")
    if not layouts or any(not CODE.match(c) for c in layouts):
        fail("refusing to write an empty or invalid layout list")
    if len(variants) != len(layouts) or any(v and not CODE.match(v) for v in variants):
        fail("variants must pair 1:1 with layouts")
    # Keep a Latin layout first: Hyprland resolves Super bindings against the
    # lead entry, and a non-Latin lead breaks every Super shortcut.
    non_latin = set("af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm np rs ru sy th tj ua".split())
    if layouts[0] in non_latin:
        fail(f"refusing a non-Latin lead layout: {layouts[0]}")

    path = Path.home() / ".config/hypr/input.lua"
    try:
        text = path.read_text()
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    if len(re.findall(r'(?m)^\s*kb_layout\s*=', text)) != 1:
        fail(f"{path} has no single active kb_layout line to update")
    if len(re.findall(r'(?m)^\s*kb_variant\s*=', text)) > 1:
        fail(f"{path} has more than one kb_variant line")

    updated = re.sub(r'(?m)^(\s*)kb_layout\s*=.*$',
                     f'\\1kb_layout = "{",".join(layouts)}",', text, count=1)
    if re.search(r'(?m)^\s*kb_variant\s*=', updated):
        updated = re.sub(r'(?m)^(\s*)kb_variant\s*=.*$',
                         f'\\1kb_variant = "{",".join(variants)}",', updated, count=1)
    else:
        def add_variant(match):
            indent = match.group(1)
            return (f'{match.group(0)}\n{indent}kb_variant = "{",".join(variants)}",')
        updated = re.sub(r'(?m)^(\s*)kb_layout\s*=.*$', add_variant, updated, count=1)
    if updated == text:
        fail("nothing to change")

    try:
        path.write_text(updated)
    except OSError as error:
        fail(f"cannot write {path}: {error}")
    try:
        before = run(["hyprctl", "configerrors"])
        run(["hyprctl", "reload"])
        errors = run(["hyprctl", "configerrors"])
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"hyprctl reload failed: {error}")
    if errors and errors != before:
        fail(f"config errors after reload: {errors}")
    print("ok")


if __name__ == "__main__":
    main()
