#!/usr/bin/env python3
"""Write kindle.html: the latest entries from feed.json as plain, script-free HTML for an e-ink browser."""
import datetime
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COUNT = 3

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Feed</title>
<style>
body { background: #fff; color: #000; font-family: Georgia, serif; font-size: 22px; line-height: 1.5; margin: 0; padding: 16px; }
h1 { font-size: 1.4em; margin: 0 0 4px 0; }
h2 { font-size: 1.15em; margin: 0 0 2px 0; text-transform: uppercase; }
h3 { font-size: 1.1em; margin: 14px 0 4px 0; }
p { margin: 8px 0; }
ul, ol { margin: 8px 0; padding-left: 28px; }
li { margin: 4px 0; }
pre { border: 1px solid #000; padding: 8px; font-size: 0.8em; white-space: pre-wrap; word-wrap: break-word; }
code { font-family: Courier, monospace; font-size: 0.9em; }
.when { font-size: 0.8em; margin: 0 0 8px 0; }
hr { border: 0; border-top: 2px solid #000; margin: 24px 0; }
</style>
</head>
<body>
<h1>The Feed</h1>
<p class="when">Updated __UPDATED__</p>
__BODY__
</body>
</html>
"""


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def inline(t):
    t = esc(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"\*([^*]+)\*", r"<i>\1</i>", t)
    t = re.sub(r"\[([^\]]+)\]\(https?://[^)\s]+\)", r"\1", t)  # keep link text, drop the link
    return t


def markdown(src):
    out, para, buf, lst, code = [], [], [], None, False

    def flush_para():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()

    def close_list():
        nonlocal lst
        if lst:
            out.append("</%s>" % lst)
            lst = None

    for line in src.replace("\r", "").split("\n"):
        if line.startswith("```"):
            if code:
                out.append("<pre>" + esc("\n".join(buf)) + "</pre>")
                buf.clear()
                code = False
            else:
                flush_para()
                close_list()
                code = True
            continue
        if code:
            buf.append(line)
            continue
        h = re.match(r"^(#{1,3})\s+(.*)$", line)
        ul = re.match(r"^\s*[-*]\s+(.*)$", line)
        ol = re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        if h:
            flush_para()
            close_list()
            out.append("<h3>" + inline(h.group(2)) + "</h3>")
        elif ul or ol:
            flush_para()
            kind = "ul" if ul else "ol"
            if lst != kind:
                close_list()
                out.append("<%s>" % kind)
                lst = kind
            out.append("<li>" + inline((ul or ol).group(1)) + "</li>")
        elif not line.strip():
            flush_para()
            close_list()
        else:
            close_list()
            para.append(line.strip())
    if code:
        out.append("<pre>" + esc("\n".join(buf)) + "</pre>")
    flush_para()
    close_list()
    return "\n".join(out)


def when(iso):
    try:
        d = datetime.datetime.fromisoformat(iso)
        return d.strftime("%a %d %b, %H:%M")
    except Exception:
        return iso


def main():
    with open(os.path.join(ROOT, "feed.json"), encoding="utf-8") as f:
        entries = json.load(f).get("entries", [])
    entries.sort(key=lambda e: e["time"], reverse=True)
    latest = entries[:COUNT]
    parts = []
    for e in latest:
        parts.append(
            "<h2>%s</h2>\n<p class=\"when\">%s</p>\n%s" % (esc(e["slot"]), esc(when(e["time"])), markdown(e["text"]))
        )
    body = "\n<hr>\n".join(parts) if parts else "<p>No entries yet.</p>"
    updated = when(latest[0]["time"]) if latest else "never"
    html = PAGE.replace("__UPDATED__", esc(updated)).replace("__BODY__", body)
    with open(os.path.join(ROOT, "kindle.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("kindle.html written with %d entries" % len(latest))


if __name__ == "__main__":
    main()