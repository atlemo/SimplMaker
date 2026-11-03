#!/usr/bin/env python3
"""Builds the simplmaker.com static site.

    python3 website/build.py            build into website/public/
    python3 website/build.py --serve    build, then serve on http://localhost:8765

Pages live in src/pages/**/index.html (a few lines of front matter, then the page body).
src/layout.html wraps every page; src/partials/*.html are included with {{include:name}}.
src/static/ is copied as it is. What ends up in public/ is exactly what gets uploaded
(scripts/publish-site.sh), apart from /updates/ and the disk image in /download/, which belong to the release scripts.

Placeholders available in pages and partials:
    {{min_os}} {{version}} {{github_url}} {{support_email}} {{year}}
    {{asset:css/style.css}}                  the file's URL with a content hash, so browsers re-fetch changes
    {{clip:name|16/10|Label shown until the video exists}}   a looping video figure
    {{changelog}}                            the release notes from ../release-notes/*.html
"""
import datetime, hashlib, html, json, re, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
SRC, OUT = ROOT / "src", ROOT / "public"

SITE_URL = "https://simplmaker.com"

# Pages that used to exist. Each becomes a small stub that sends visitors (and search engines) to the new place.
# A meta refresh plus a canonical link works on any static host, with no server configuration.
REDIRECTS = {"/pricing/": "/download/", "/refunds/": "/download/", "/terms/": "/license/", "/eula/": "/license/"}


VARS = {
    "min_os": "macOS 15",
    "version": (REPO / "VERSION").read_text().strip(),
    "github_url": "https://github.com/atlemo/SimplMaker",
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


def page_html(layout, *, title, description, nav="", route, content, body_class="", noindex=False, raw_title=False):
    values = {
        "title": html.escape(title if raw_title else f"{title} · SimplMaker"),
        "description": html.escape(description, quote=True),
        "canonical": SITE_URL + route,
        "robots": "noindex, follow" if noindex else "index, follow, max-image-preview:large",
        "body_class": body_class,
        "content": content,
        # The docs search script is only needed on the docs.
        "docs_script": f'<script src="{asset("js/docs.js")}" defer></script>' if route.startswith("/docs/") else "",
    }
    for item in ("features", "compare", "docs"):
        values[f"cur_{item}"] = ' aria-current="page"' if nav == item else ""
    out = layout
    for k, v in values.items():
        out = out.replace("{{page:%s}}" % k, v)
    return render(out)


def write(route, text):
    if route == "/404.html":                       # the error page is served as a plain file
        dest = OUT / "404.html"
    else:
        dest = OUT / route.strip("/") / "index.html" if route != "/" else OUT / "index.html"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)


def redirect_html(target):
    url = SITE_URL + target
    return ("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"UTF-8\" />"
            f"<title>Moved · SimplMaker</title>"
            f"<meta http-equiv=\"refresh\" content=\"0; url={target}\" />"
            f"<link rel=\"canonical\" href=\"{url}\" />"
            "<meta name=\"robots\" content=\"noindex, follow\" />"
            f"</head><body><p>This page has moved to <a href=\"{target}\">{url}</a>.</p></body></html>\n")


def lastmod(path):
    return datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()


def image_info(name):
    """The screenshot website/src/static/docs/img/<name>.(jpg|png): (url, width, height), or None."""
    for ext in ("jpg", "png"):
        path = SRC / "static" / "docs" / "img" / f"{name}.{ext}"
        if path.exists():
            data = path.read_bytes()
            if ext == "png":
                w, h = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
            else:  # JPEG: find the start-of-frame marker
                i = 2
                while i < len(data):
                    marker = data[i + 1]
                    if marker in (0xC0, 0xC1, 0xC2):
                        h, w = int.from_bytes(data[i + 5:i + 7], "big"), int.from_bytes(data[i + 7:i + 9], "big")
                        break
                    i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
            return (asset(f"docs/img/{name}.{ext}"), w, h)
    return None


def build_docs(layout, urls, docs_out):
    """Documentation: src/docs/<section>/<page>.md, ordered and grouped by src/docs/_nav.txt.
    Appends (url, lastmod) to urls, and each page's plain facts to docs_out (for llms.txt)."""
    from mdconv import Converter
    root = SRC / "docs"
    groups, order = [], []          # groups: (title, [path]) ; order: [path]
    for line in (root / "_nav.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#!"):
            continue
        if line.startswith("## "):
            groups.append((line[3:].strip(), []))
        else:
            groups[-1][1].append(line)
            order.append(line)
    pages = {}
    for path in order:
        f = root / f"{path}.md"
        if not f.exists():
            sys.exit(f"docs nav lists {path}, but {f.relative_to(REPO)} is missing")
        meta, body = front_matter(f.read_text(), f)
        pages[path] = {"meta": meta, "body": body}
    unlisted = {str(p.relative_to(root).with_suffix("")) for p in root.rglob("*.md")} - set(order)
    if unlisted:
        sys.exit(f"docs pages not in _nav.txt: {sorted(unlisted)}")

    def resolve(target):
        path, _, frag = target.partition("#")
        if path not in pages:
            sys.exit(f"broken doc link: doc:{target}")
        return f"/docs/{path}/" + (f"#{frag}" if frag else "")

    group_of = {p: g for g, items in groups for p in items}
    missing, search = [], []

    def nav_html(current, suffix=""):
        # The menu comes twice on a docs page (phone and desktop), so each copy has its own ids.
        out = [f'<div class="docs-search"><label class="visually-hidden" for="docs-q{suffix}">Search the docs</label>'
               f'<input id="docs-q{suffix}" type="search" placeholder="Search the docs" autocomplete="off" />'
               f'<ul class="docs-results" id="docs-results{suffix}" hidden></ul></div><nav class="docs-groups" aria-label="Documentation">']
        for title, items in groups:
            out.append(f'<p class="mono docs-group">{html.escape(title)}</p><ul>')
            for p in items:
                cur = ' aria-current="page"' if p == current else ""
                out.append(f'<li><a href="/docs/{p}/"{cur}>{html.escape(pages[p]["meta"]["title"])}</a></li>')
            out.append("</ul>")
        out.append("</nav>")
        return "".join(out)

    for i, path in enumerate(order):
        meta, body = pages[path]["meta"], pages[path]["body"]
        conv = Converter(resolve, image_info)
        article = conv.convert(body)
        missing += [(path, m) for m in conv.missing_shots]
        toc = "".join(f'<li class="toc-{lvl}"><a href="#{hid}">{html.escape(txt)}</a></li>' for lvl, hid, txt in conv.headings)
        prev_p = order[i - 1] if i > 0 else None
        next_p = order[i + 1] if i + 1 < len(order) else None
        pn = ""
        if prev_p or next_p:
            pn = '<nav class="docs-pager" aria-label="Previous and next">'
            pn += (f'<a class="prev" href="/docs/{prev_p}/"><span class="mono">Previous</span>{html.escape(pages[prev_p]["meta"]["title"])}</a>' if prev_p else "<span></span>")
            pn += (f'<a class="next" href="/docs/{next_p}/"><span class="mono">Next</span>{html.escape(pages[next_p]["meta"]["title"])}</a>' if next_p else "")
            pn += "</nav>"
        lead = f'<p class="docs-lead">{html.escape(meta["description"])}</p>'
        crumbs = {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "SimplMaker", "item": SITE_URL + "/"},
            {"@type": "ListItem", "position": 2, "name": "Docs", "item": SITE_URL + "/docs/"},
            {"@type": "ListItem", "position": 3, "name": meta["title"], "item": SITE_URL + f"/docs/{path}/"}]}
        content = (
            f'<script type="application/ld+json">{json.dumps(crumbs, ensure_ascii=False)}</script>'
            f'<div class="docs-wrap"><details class="docs-mobile"><summary>Documentation menu</summary>{nav_html(path, "-mobile")}</details>'
            f'<aside class="docs-nav">{nav_html(path)}</aside>'
            f'<article class="docs-article"><p class="mono docs-crumb"><a href="/docs/">Docs</a> / {html.escape(group_of[path])}</p>'
            f'<h1>{html.escape(meta["title"])}</h1>{lead}{article}{pn}</article>'
            f'<aside class="docs-toc"><p class="mono">On this page</p><ul>{toc}</ul></aside></div>')
        route = f"/docs/{path}/"
        write(route, page_html(layout, title=f'{meta["title"]} · Docs', description=meta["description"], nav="docs",
                               route=route, content=content, body_class="docs"))
        urls.append((SITE_URL + route, lastmod(f)))
        text = re.sub(r"<[^>]+>", " ", article)
        search.append({"t": meta["title"], "u": route, "g": group_of[path], "h": [t for _, _, t in conv.headings],
                       "x": re.sub(r"\s+", " ", html.unescape(text)).strip()[:4000]})
        docs_out.append({"route": route, "title": meta["title"], "description": meta["description"],
                         "group": group_of[path], "body": body})

    # The docs home: every group and page.
    cards = []
    for title, items in groups:
        links = "".join(
            f'<li><a href="/docs/{p}/"><span class="mid-link">{html.escape(pages[p]["meta"]["title"])}</span>'
            f'<span class="muted">{html.escape(pages[p]["meta"]["description"])}</span></a></li>' for p in items)
        cards.append(f'<section class="docs-home-group"><h2 class="mono">{html.escape(title)}</h2><ul>{links}</ul></section>')
    home = (
        '<section class="page-head wrap"><p class="mono">Docs</p>'
        '<h1 class="display display-page">How to use it.</h1>'
        '<p class="lead">Every tool and feature, in short pages. New here? Start with the quick start.</p>'
        '<div class="docs-home-search"><input id="docs-q" type="search" placeholder="Search the docs" autocomplete="off" aria-label="Search the docs" />'
        '<ul class="docs-results" id="docs-results" hidden></ul></div></section>'
        f'<section class="wrap docs-home" style="padding-bottom:var(--section)">{"".join(cards)}</section>')
    write("/docs/", page_html(layout, title="Docs", description="SimplMaker documentation: getting started, sketching, every tool and feature, exporting for 3D printing, shortcuts and settings.",
                              nav="docs", route="/docs/", content=home, body_class="docs-home-page"))
    urls.append((SITE_URL + "/docs/", lastmod(root / "_nav.txt")))
    (OUT / "docs" / "search.json").write_text(json.dumps(search, ensure_ascii=False, separators=(",", ":")))
    return len(order), missing


def doc_links(body):
    """Docs pages link as [x](doc:section/page); in llms-full.txt those become absolute URLs."""
    body = re.sub(r"^!\[[^\]]*\]\(shot:[^)]*\)\s*$", "", body, flags=re.M)   # screenshots mean nothing to a text reader
    return re.sub(r"\]\(doc:([^)]+)\)",
                  lambda m: "](" + SITE_URL + "/docs/" + m.group(1).replace("#", "/#", 1) + ("" if "#" in m.group(1) else "/") + ")",
                  body)


def write_llms(pages, docs):
    """llms.txt (an index for AI assistants and crawlers) and llms-full.txt (every doc page as plain Markdown)."""
    def line(route_or_url, title, desc):
        url = route_or_url if route_or_url.startswith("http") else SITE_URL + route_or_url
        return f"- [{title}]({url}): {desc}"

    short = {"/features/": "Features", "/compare/": "Compare with other CAD tools",
             "/download/": "Download", "/changelog/": "Changelog", "/support/": "Support",
             "/privacy/": "Privacy policy", "/license/": "License and source code"}
    for p in pages:
        p["title"] = short.get(p["route"], p["title"])
    product = [p for p in pages if p["route"] in short and p["route"] not in ("/privacy/", "/license/")]
    legal = [p for p in pages if p["route"] in ("/privacy/", "/license/")]
    lines = [
        "# SimplMaker", "",
        "> SimplMaker is native parametric CAD for Mac, made for makers who 3D print. Sketch a profile, extrude it, "
        "name the dimensions as parameters, and the whole part rebuilds when a number changes. It imports and exports "
        "STEP and exports STL for the slicer. It is free and open source (GPL-3.0-or-later), with no subscription "
        "and no account. Requires macOS 15 or later on Apple Silicon.",
        "",
        "## Key facts", "",
        f"- Product: SimplMaker, version {VARS['version']}, by Atle Mo",
        "- Platform: macOS 15 or later, Apple Silicon. No Windows, Linux or iPad version.",
        "- Price: free. No subscription, no account, no license key.",
        f"- Source code: {VARS['github_url']}",
        "- Files: parts are plain files on the user's Mac. Imports STEP; exports STEP and STL.",
        "- License: GNU General Public License, version 3 or later. The name and icon are not covered by it.",
        "- Not included: assemblies, CAM, simulation, rendering.",
        f"- Support: {VARS['support_email']}", "",
        "## Product", "",
        *[line(p["route"], p["title"], p["description"]) for p in product], "",
        "## Documentation", "",
    ]
    group = None
    for d in docs:
        if d["group"] != group:
            group = d["group"]
            lines += ["", f"### {group}", ""]
        lines.append(line(d["route"], d["title"], d["description"]))
    lines += ["", "## Legal", "", *[line(p["route"], p["title"], p["description"]) for p in legal], "",
              "## Optional", "",
              f"- [Full documentation as plain Markdown]({SITE_URL}/llms-full.txt): every docs page in one file", ""]
    (OUT / "llms.txt").write_text("\n".join(lines))

    full = ["# SimplMaker documentation", "",
            f"> Every docs page of SimplMaker {VARS['version']}, in Markdown. Index: {SITE_URL}/llms.txt", ""]
    for d in docs:
        full += ["", "---", "", f"## {d['title']}", "", f"Section: {d['group']}. URL: {SITE_URL}{d['route']}", "",
                 d["description"], "", doc_links(d["body"]).strip(), ""]
    (OUT / "llms-full.txt").write_text("\n".join(full))


def build():
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SRC / "static", OUT)
    layout = includes((SRC / "layout.html").read_text())
    urls, pages, docs = [], [], []
    for page in sorted((SRC / "pages").rglob("*.html")):
        meta, body = front_matter(page.read_text(), page)
        rel = page.relative_to(SRC / "pages")
        route = "/" + str(rel.parent).strip(".") + ("/" if str(rel.parent) != "." else "")
        if str(rel.parent) == "404":                  # src/pages/404/index.html is served as /404.html
            route = "/404.html"
        write(route, page_html(layout, title=meta["title"], description=meta["description"], nav=meta.get("nav", ""),
                               route=route, content=render(body), body_class=meta.get("class", ""),
                               noindex=bool(meta.get("noindex")), raw_title=bool(meta.get("raw_title"))))
        if not meta.get("noindex"):
            urls.append((SITE_URL + route, lastmod(page)))
            pages.append({"route": route, "title": render(meta["title"]), "description": render(meta["description"])})
    for old, new in REDIRECTS.items():
        write(old, redirect_html(new))
    doc_count, missing = build_docs(layout, urls, docs)
    sitemap = "".join(f"<url><loc>{u}</loc><lastmod>{d}</lastmod></url>\n" for u, d in urls)
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + sitemap + "</urlset>\n")
    write_llms(pages, docs)
    print(f"built {len(urls)} indexable pages ({doc_count} doc pages) into {OUT.relative_to(REPO)}")
    if missing:
        names = sorted({m for _, m in missing})
        print(f"  {len(names)} screenshot(s) still to come: {', '.join(names)}")


if __name__ == "__main__":
    build()
    if "--serve" in sys.argv:
        import functools, http.server
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(OUT))
        print("serving http://localhost:8765")
        http.server.ThreadingHTTPServer(("127.0.0.1", 8765), handler).serve_forever()
