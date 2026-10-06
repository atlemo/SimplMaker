#!/usr/bin/env python3
"""Builds the simplmaker.com static site.

    python3 website/build.py            build into website/public/
    python3 website/build.py --serve    build, then serve on http://localhost:8765

Pages live in src/pages/**/index.html (a few lines of front matter, then the page body).
src/layout.html wraps every page; src/partials/*.html are included with {{include:name}}.
src/static/ is copied as it is. What ends up in public/ is exactly what gets uploaded
(scripts/publish-site.sh), apart from /updates/ and /download/, which belong to the release scripts.

Placeholders available in pages and partials:
    {{price}} {{trial_days}} {{min_os}} {{version}} {{buy_url}} {{support_email}} {{year}}
    {{asset:css/style.css}}                  the file's URL with a content hash, so browsers re-fetch changes
    {{clip:name|16/10|Label shown until the video exists}}   a looping video figure
    {{changelog}}                            the release notes from ../release-notes/*.html
"""
import hashlib, html, re, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
SRC, OUT = ROOT / "src", ROOT / "public"

SITE_URL = "https://simplmaker.com"


def read_conf(path):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip()
    return values


conf = read_conf(REPO / "Packaging" / "licensing.conf")
VARS = {
    "price": "49",                      # keep in step with the Polar product
    "trial_days": "14",
    "min_os": "macOS 26",
    "version": (REPO / "VERSION").read_text().strip(),
    "buy_url": conf.get("BUY_URL", "#"),
    "support_email": "support@simplmaker.com",
    "year": "2026",
}


def front_matter(text, path):
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        sys.exit(f"{path}: missing front matter")
    meta = {}
    for line in m.group(1).splitlines():
        key, _, val = line.partition(":")
        meta[key.strip()] = val.strip()
    return meta, text[m.end():]


def asset(rel):
    data = (SRC / "static" / rel).read_bytes()
    return f"/{rel}?v={hashlib.sha1(data).hexdigest()[:8]}"


def clip(name, ratio, label):
    ratio = ratio.replace("/", " / ")
    poster = f' poster="/video/{name}.jpg"' if (SRC / "static" / "video" / f"{name}.jpg").exists() else ""
    return (
        f'<figure class="clip" style="--ar: {ratio}" data-label="{html.escape(label, quote=True)}">'
        f'<video muted loop playsinline preload="none"{poster} '
        f'data-mp4="/video/{name}.mp4" data-webm="/video/{name}.webm" aria-label="{html.escape(label, quote=True)}"></video>'
        f"</figure>"
    )


def changelog():
    out = []
    files = sorted((REPO / "release-notes").glob("*.html"),
                   key=lambda p: [int(x) for x in re.findall(r"\d+", p.stem)], reverse=True)
    for f in files:
        out.append(f'<section class="release">{f.read_text()}</section>')
    return "\n".join(out) or "<p>No releases yet.</p>"


def includes(text):
    return re.sub(r"\{\{include:([\w./-]+)\}\}", lambda m: includes((SRC / "partials" / m.group(1)).read_text()), text)


def render(text):
    text = includes(text)
    text = re.sub(r"\{\{asset:([^}]+)\}\}", lambda m: asset(m.group(1)), text)
    text = re.sub(r"\{\{clip:([^|}]+)\|([^|}]+)\|([^}]+)\}\}", lambda m: clip(*m.groups()), text)
    text = text.replace("{{changelog}}", changelog())

    def var(m):
        if m.group(1) not in VARS:
            sys.exit(f"unknown placeholder {{{{{m.group(1)}}}}}")
        return VARS[m.group(1)]
    return re.sub(r"\{\{(\w+)\}\}", var, text)


def build():
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SRC / "static", OUT)
    layout = includes((SRC / "layout.html").read_text())
    urls = []
    for page in sorted((SRC / "pages").rglob("*.html")):
        meta, body = front_matter(page.read_text(), page)
        rel = page.relative_to(SRC / "pages")
        route = "/" + str(rel.parent).strip(".") + ("/" if str(rel.parent) != "." else "")
        title = meta["title"]
        full_title = title if meta.get("raw_title") else f"{title} · SimplMaker"
        nav = meta.get("nav", "")
        values = {
            "title": html.escape(full_title),
            "description": html.escape(meta["description"], quote=True),
            "canonical": SITE_URL + route,
            "robots": "noindex, follow" if meta.get("noindex") else "index, follow, max-image-preview:large",
            "body_class": meta.get("class", ""),
            "content": render(body),
        }
        for item in ("features", "pricing", "compare", "docs"):
            values[f"cur_{item}"] = ' aria-current="page"' if nav == item else ""
        out = layout
        for k, v in values.items():
            out = out.replace("{{page:%s}}" % k, v)
        out = render(out)
        dest = OUT / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(out)
        if not meta.get("noindex"):
            urls.append(SITE_URL + route)
    sitemap = "".join(f"<url><loc>{u}</loc></url>\n" for u in urls)
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + sitemap + "</urlset>\n")
    print(f"built {len(urls)} indexable pages into {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    build()
    if "--serve" in sys.argv:
        import functools, http.server
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(OUT))
        print("serving http://localhost:8765")
        http.server.ThreadingHTTPServer(("127.0.0.1", 8765), handler).serve_forever()
