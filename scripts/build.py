#!/usr/bin/env python3
"""Validate feed entries and build the static site.

  python3 scripts/build.py --check          validate entries/, exit 1 on any problem
  python3 scripts/build.py --out _site      validate, then build _site/ (index.html + feed.json)
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRIES = os.path.join(ROOT, "entries")
ALLOWED_SLOTS = {"physics", "math", "dsa"}   # add new slots here
MAX_TEXT = 6000
KEEP = 200
FILENAME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([a-z]+)\.json$")

# Things that must never be published in this public repo.
BLOCKED = [
    (re.compile(r"ghp_[A-Za-z0-9]{20,}"), "GitHub token"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "GitHub fine-grained token"),
    (re.compile(r"sk-ant-[A-Za-z0-9_-]{10,}"), "Anthropic API key"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "email address"),
    (re.compile(r"/Users/[A-Za-z0-9._-]+"), "home-folder path"),
    (re.compile(r"(?i)<\s*script"), "script tag"),
]


def load_entries():
    problems, entries = [], []
    if not os.path.isdir(ENTRIES):
        return ["entries/ folder is missing"], entries
    for name in sorted(os.listdir(ENTRIES)):
        if name == ".gitkeep":
            continue
        path = os.path.join(ENTRIES, name)
        m = FILENAME.match(name)
        if not m:
            problems.append(f"{name}: filename must look like 2026-11-26T11-15-00-physics.json")
            continue
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            problems.append(f"{name}: not valid JSON ({e})")
            continue
        if not isinstance(data, dict) or set(data) != {"slot", "time", "text"}:
            problems.append(f"{name}: must have exactly the keys slot, time, text")
            continue
        slot, when, text = data["slot"], data["time"], data["text"]
        if slot not in ALLOWED_SLOTS:
            problems.append(f"{name}: unknown slot '{slot}'")
        if slot != m.group(1):
            problems.append(f"{name}: slot '{slot}' does not match filename")
        try:
            datetime.datetime.fromisoformat(when)
        except Exception:
            problems.append(f"{name}: 'time' is not an ISO timestamp")
        if not isinstance(text, str) or not text.strip():
            problems.append(f"{name}: 'text' is empty")
            continue
        if len(text) > MAX_TEXT:
            problems.append(f"{name}: text is {len(text)} chars (limit {MAX_TEXT})")
        for pattern, label in BLOCKED:
            if pattern.search(text):
                problems.append(f"{name}: contains a {label}")
        entries.append(data)
    return problems, entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args()
    if not args.check and not args.out:
        ap.error("use --check or --out DIR")

    problems, entries = load_entries()
    if not os.path.isfile(os.path.join(ROOT, "index.html")):
        problems.append("index.html is missing")
    if problems:
        print("Validation failed:")
        for p in problems:
            print(" -", p)
        sys.exit(1)
    print(f"OK: {len(entries)} entries valid")

    if args.out:
        entries.sort(key=lambda e: e["time"])
        out = os.path.abspath(args.out)
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        shutil.copy(os.path.join(ROOT, "index.html"), out)
        with open(os.path.join(out, "feed.json"), "w", encoding="utf-8") as f:
            json.dump({"entries": entries[-KEEP:]}, f, ensure_ascii=False)
        print(f"Built {out} with {min(len(entries), KEEP)} entries")


if __name__ == "__main__":
    main()