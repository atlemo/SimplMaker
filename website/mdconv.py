"""A small Markdown converter for the documentation pages (no dependencies).

Supported: ## and ### headings (with anchors), paragraphs, bullet and numbered lists (nested by two spaces),
tables, fenced code, horizontal rules, callouts, screenshots, and inline **bold**, *italic*, `code`, links and keys.

    :::tip Optional title          callouts: tip, note, warning
    Body, in Markdown.
    :::

    ![Caption](shot:name)          a screenshot, website/src/static/docs/img/name.jpg (or .png), with the caption
    [[⌘Z]]  [[E]]                  a keyboard key
    [text](doc:section/page)       a link to another doc page, checked when the site is built
    [text](doc:section/page#id)

Nothing here is general-purpose Markdown: it only has what the docs use.
"""
import html, re
from pathlib import Path

CALLOUTS = {"tip": "Tip", "note": "Note", "warning": "Careful"}


def slugify(text):
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[^\w\s-]", "", text.lower())
    return re.sub(r"[\s_]+", "-", text).strip("-")


class Converter:
    def __init__(self, resolve_link, image_info):
        self.resolve_link = resolve_link      # "section/page#id" -> "/docs/section/page/#id"
        self.image_info = image_info          # name -> (url, width, height) or None
        self.headings = []                    # (level, id, text)
        self.missing_shots = []

    # ---------- inline ----------
    def inline(self, text):
        spans = []

        def keep(m):
            spans.append("<code>" + html.escape(m.group(1)) + "</code>")
            return f"\x00{len(spans) - 1}\x00"

        text = re.sub(r"`([^`]+)`", keep, text)
        text = html.escape(text, quote=False)
        text = re.sub(r"\[\[(.+?)\]\]", lambda m: "<kbd>" + m.group(1) + "</kbd>", text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)

        def link(m):
            label, target = m.group(1), m.group(2)
            if target.startswith("doc:"):
                target = self.resolve_link(target[4:])
            external = target.startswith("http")
            attrs = ' rel="noopener"' if external else ""
            return f'<a href="{target}"{attrs}>{label}</a>'

        text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
        return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], text)

    # ---------- blocks ----------
    def convert(self, source):
        lines = source.strip("\n").split("\n")
        out, i = [], 0
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                i += 1
            elif line.startswith("```"):
                j = i + 1
                while j < len(lines) and not lines[j].startswith("```"):
                    j += 1
                out.append("<pre><code>" + html.escape("\n".join(lines[i + 1:j])) + "</code></pre>")
                i = j + 1
            elif line.startswith(":::"):
                kind, _, title = line[3:].strip().partition(" ")
                j = i + 1
                while j < len(lines) and lines[j].strip() != ":::":
                    j += 1
                body = Converter.convert(self, "\n".join(lines[i + 1:j]))
                label = html.escape(title or CALLOUTS.get(kind, kind.title()))
                out.append(f'<aside class="callout callout-{kind}"><p class="callout-title mono">{label}</p>{body}</aside>')
                i = j + 1
            elif re.match(r"#{2,3} ", line):
                level = len(line) - len(line.lstrip("#"))
                text = line[level:].strip()
                hid = slugify(text)
                self.headings.append((level, hid, re.sub(r"[`*]", "", text)))
                out.append(f'<h{level} id="{hid}"><a class="anchor" href="#{hid}" aria-label="Link to this section">#</a>{self.inline(text)}</h{level}>')
                i += 1
            elif line.strip() == "---":
                out.append("<hr />")
                i += 1
            elif line.startswith("|"):
                j = i
                while j < len(lines) and lines[j].startswith("|"):
                    j += 1
                out.append(self.table(lines[i:j]))
                i = j
            elif re.match(r"!\[.*\]\(shot:[\w-]+\)\s*$", line):
                m = re.match(r"!\[(.*)\]\(shot:([\w-]+)\)", line)
                out.append(self.figure(m.group(1), m.group(2)))
                i += 1
            elif re.match(r"(\s*)([-*]|\d+\.) ", line):
                j = i
                while j < len(lines) and (re.match(r"\s*([-*]|\d+\.) ", lines[j]) or (lines[j].startswith("  ") and lines[j].strip())):
                    j += 1
                block, _ = self.list_block(lines[i:j], 0)
                out.append(block)
                i = j
            else:
                j = i
                while j < len(lines) and lines[j].strip() and not re.match(r"(#{2,3} |```|:::|\||!\[.*\]\(shot:|\s*([-*]|\d+\.) )", lines[j]):
                    j += 1
                out.append("<p>" + self.inline(" ".join(l.strip() for l in lines[i:j])) + "</p>")
                i = j
        return "\n".join(out)

    def list_block(self, lines, base):
        """Builds a list from lines whose markers sit at indent `base`; returns (html, lines used)."""
        first = re.match(r"\s*(\d+)\. ", lines[0])
        tag = "ol" if first else "ul"
        attr = f' start="{first.group(1)}"' if first and first.group(1) != "1" else ""
        items, i = [], 0
        while i < len(lines):
            m = re.match(r"(\s*)([-*]|\d+\.) (.*)", lines[i])
            if not m or len(m.group(1)) != base:
                break
            text, i = [m.group(3)], i + 1
            nested = ""
            while i < len(lines):
                nm = re.match(r"(\s*)([-*]|\d+\.) ", lines[i])
                if nm and len(nm.group(1)) > base:
                    sub = []
                    while i < len(lines) and (not re.match(r"(\s*)([-*]|\d+\.) ", lines[i]) or len(re.match(r"(\s*)", lines[i]).group(1)) > base):
                        sub.append(lines[i]); i += 1
                    nested, _ = self.list_block(sub, len(re.match(r"(\s*)", sub[0]).group(1)))
                elif not nm and lines[i].startswith(" " * (base + 2)) and lines[i].strip():
                    text.append(lines[i].strip()); i += 1
                else:
                    break
            items.append("<li>" + self.inline(" ".join(text)) + nested + "</li>")
        return f"<{tag}{attr}>" + "".join(items) + f"</{tag}>", i

    def table(self, rows):
        def cells(r):
            return [c.strip() for c in r.strip().strip("|").split("|")]
        head = cells(rows[0])
        body = [cells(r) for r in rows[2:]]
        th = "".join(f"<th>{self.inline(c)}</th>" for c in head)
        tb = "".join("<tr>" + "".join(f"<td>{self.inline(c)}</td>" for c in r) + "</tr>" for r in body)
        return f'<div class="table-scroll"><table class="doc-table"><thead><tr>{th}</tr></thead><tbody>{tb}</tbody></table></div>'

    def figure(self, caption, name):
        info = self.image_info(name)
        cap = f"<figcaption>{self.inline(caption)}</figcaption>" if caption else ""
        if not info:
            self.missing_shots.append(name)
            return (f'<figure class="shot missing"><div class="shot-missing mono">Screenshot to come: {html.escape(name)}</div>{cap}</figure>')
        url, w, h = info
        return (f'<figure class="shot"><img src="{url}" width="{w}" height="{h}" style="max-width:{w // 2}px" alt="{html.escape(caption, quote=True)}" loading="lazy" />{cap}</figure>')
