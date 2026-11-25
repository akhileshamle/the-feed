#!/usr/bin/env python3
"""One-time: split the old feed.json into one file per entry under entries/."""
import datetime
import json
import os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = os.path.join(root, "feed.json")
dst = os.path.join(root, "entries")
os.makedirs(dst, exist_ok=True)

with open(src, encoding="utf-8") as f:
    data = json.load(f)

n = 0
for e in data.get("entries", []):
    t = datetime.datetime.fromisoformat(e["time"])
    name = f"{t.strftime('%Y-%m-%dT%H-%M-%S')}-{e['slot']}.json"
    with open(os.path.join(dst, name), "w", encoding="utf-8") as out:
        json.dump({"slot": e["slot"], "time": e["time"], "text": e["text"]}, out, ensure_ascii=False, indent=1)
    n += 1
print(f"Wrote {n} entry files to entries/. Now run: git rm feed.json")