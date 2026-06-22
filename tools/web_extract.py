#!/usr/bin/env python3
"""web_extract.py — pure HTML -> markdown extraction (no I/O, no network).

Core layer of the self-hosted web-ingest tool: given an HTML string it builds a
forgiving DOM, selects the main-content block by text-density, and serializes
that subtree to markdown. Stdlib only (html.parser). Zero third-party deps.

Main-content selection uses a text-density heuristic in the lineage of the
arc90/Mozilla Readability algorithm: strip boilerplate, then pick the container
whose own text dominates and whose text is not mostly link anchors (nav/menus).
Source: Readability density heuristic — https://github.com/mozilla/readability
(scoring by character count, penalizing high link density).
"""
from __future__ import annotations

import re
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

# Tags dropped wholesale before extraction — never main content.
BOILERPLATE_TAGS = {
    "head", "script", "style", "noscript", "nav", "header", "footer", "aside",
    "form", "svg", "iframe", "button", "input", "select", "template",
}
# Self-closing / void elements that never receive children (HTML spec §12.1.2).
VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}
INLINE_TAGS = {
    "a", "strong", "b", "em", "i", "code", "span", "sub", "sup",
    "u", "small", "mark", "abbr", "br", "img",
}
# Containers that are candidates to hold the main article body.
CONTAINER_TAGS = {"article", "main", "section", "div", "body"}
# Semantic tags that, when present and substantial, ARE the main content.
SEMANTIC_MAIN_TAGS = {"main", "article"}
# Class/id name signals. Source: Mozilla Readability REGEXPS.positive / .negative
# (https://github.com/mozilla/readability) — name-based candidate weighting.
POSITIVE_RE = re.compile(
    r"article|body|content|entry|main|page|post|text|blog|story|markdown|doc", re.I)
NEGATIVE_RE = re.compile(
    r"comment|contact|foot|footer|masthead|media|meta|promo|related|scroll|"
    r"shoutbox|sidebar|sponsor|tags|tool|widget|banner|nav|menu|breadcrumb|"
    r"pager|popup|legal|copyright|disclaimer", re.I)
# Minimum text length for a block to be considered an article body.
MIN_CONTENT_CHARS = 200


class Node:
    """Minimal DOM node. `text` is set only for text leaves (tag == '#text')."""

    __slots__ = ("tag", "attrs", "children", "text", "parent")

    def __init__(self, tag: str, attrs: dict | None = None):
        self.tag = tag
        self.attrs = attrs or {}
        self.children: list[Node] = []
        self.text: str = ""
        self.parent: Node | None = None

    def add(self, node: "Node") -> None:
        node.parent = self
        self.children.append(node)


class _TreeBuilder(HTMLParser):
    """Forgiving HTML -> Node tree. Tolerates unclosed/misnested tags."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("#root")
        self._stack = [self.root]

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        node = Node(tag, dict(attrs))
        self._stack[-1].add(node)
        if tag not in VOID_TAGS:
            self._stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self._stack[-1].add(Node(tag.lower(), dict(attrs)))

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in VOID_TAGS:
            return
        for i in range(len(self._stack) - 1, 0, -1):  # find nearest open match
            if self._stack[i].tag == tag:
                del self._stack[i:]
                return

    def handle_data(self, data):
        if data.strip():
            leaf = Node("#text")
            leaf.text = data
            self._stack[-1].add(leaf)


def parse_html(html: str) -> Node:
    builder = _TreeBuilder()
    builder.feed(html)
    return builder.root


# --- measurement -----------------------------------------------------------
def _text_len(node: Node) -> int:
    if node.tag == "#text":
        return len(node.text.strip())
    return sum(_text_len(c) for c in node.children)


def _link_text_len(node: Node) -> int:
    if node.tag == "a":
        return _text_len(node)
    return sum(_link_text_len(c) for c in node.children)


def _strip_boilerplate(node: Node) -> None:
    node.children = [c for c in node.children if c.tag not in BOILERPLATE_TAGS]
    for child in node.children:
        _strip_boilerplate(child)


def _candidates(node: Node, out: list[Node]) -> None:
    if node.tag in CONTAINER_TAGS:
        out.append(node)
    for child in node.children:
        _candidates(child, out)


def _name_weight(node: Node) -> float:
    """Readability-style class/id name signal: boost content, penalize chrome."""
    name = f"{node.attrs.get('class', '')} {node.attrs.get('id', '')}"
    if NEGATIVE_RE.search(name):
        return 0.2  # heavy penalty — footer/nav/sidebar/copyright
    if POSITIVE_RE.search(name):
        return 1.5  # boost — content/article/main/post
    return 1.0


def _score(node: Node) -> float:
    total = _text_len(node)
    if total < MIN_CONTENT_CHARS:
        return -1.0
    link_density = _link_text_len(node) / total if total else 1.0
    return total * (1.0 - link_density) * _name_weight(node)


def main_content(root: Node) -> Node:
    """Select the main-content container (Readability-lite); fall back to root.

    Prefer a substantial <main>/<article>; otherwise score every container by
    text volume, link density, and class/id name signal, and take the best.
    """
    _strip_boilerplate(root)
    cands: list[Node] = []
    _candidates(root, cands)
    semantic = [n for n in cands
                if n.tag in SEMANTIC_MAIN_TAGS and _text_len(n) >= MIN_CONTENT_CHARS]
    pool = semantic or cands
    best, best_score = root, 0.0
    for node in pool:
        score = _score(node)
        if score > best_score:
            best, best_score = node, score
    return best


# --- markdown serialization ------------------------------------------------
def _render_inline(node: Node) -> str:
    if node.tag == "#text":
        return node.text.replace("\n", " ")
    if node.tag == "br":
        return "  \n"
    if node.tag == "img":
        return f"![{node.attrs.get('alt', '')}]({node.attrs.get('src', '')})"
    inner = "".join(_render_inline(c) for c in node.children).strip()
    if node.tag == "a" and node.attrs.get("href"):
        return f"[{inner}]({node.attrs['href']})"
    if node.tag in ("strong", "b"):
        return f"**{inner}**"
    if node.tag in ("em", "i"):
        return f"*{inner}*"
    if node.tag == "code":
        return f"`{inner}`"
    return inner


def _render_list(node: Node, ordered: bool) -> str:
    lines = []
    for i, li in enumerate((c for c in node.children if c.tag == "li"), 1):
        marker = f"{i}. " if ordered else "- "
        lines.append(marker + _render_children(li).strip().replace("\n", " "))
    return "\n".join(lines) + "\n\n"


def _render_block(node: Node) -> str:
    tag = node.tag
    if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
        return "#" * int(tag[1]) + " " + _render_inline(node).strip() + "\n\n"
    if tag == "p":
        return _render_inline(node).strip() + "\n\n"
    if tag == "ul":
        return _render_list(node, ordered=False)
    if tag == "ol":
        return _render_list(node, ordered=True)
    if tag == "blockquote":
        return "> " + _render_children(node).strip().replace("\n", "\n> ") + "\n\n"
    if tag == "pre":
        return "```\n" + _text_of(node).strip("\n") + "\n```\n\n"
    if tag == "hr":
        return "---\n\n"
    return _render_children(node)


def _text_of(node: Node) -> str:
    if node.tag == "#text":
        return node.text
    return "".join(_text_of(c) for c in node.children)


def _render_children(node: Node) -> str:
    out, inline_run = [], []
    for child in node.children:
        if child.tag == "#text" or child.tag in INLINE_TAGS:
            inline_run.append(_render_inline(child))
        else:
            if inline_run:
                out.append("".join(inline_run).strip() + "\n\n")
                inline_run = []
            out.append(_render_block(child))
    if inline_run:
        out.append("".join(inline_run).strip() + "\n\n")
    return "".join(out)


# --- public API ------------------------------------------------------------
def extract_title(root: Node) -> str:
    for node in _iter(root):
        if node.tag == "title":
            return _text_of(node).strip()
    for node in _iter(root):
        if node.tag == "h1":
            return _render_inline(node).strip()
    return ""


def extract_links(root: Node, base_url: str) -> list[str]:
    seen, out = set(), []
    for node in _iter(root):
        if node.tag == "a" and node.attrs.get("href"):
            href = urljoin(base_url, node.attrs["href"].strip())
            if urlparse(href).scheme in ("http", "https") and href not in seen:
                seen.add(href)
                out.append(href.split("#")[0])
    return out


def _iter(node: Node):
    yield node
    for child in node.children:
        yield from _iter(child)


def _collapse_blanks(text: str) -> str:
    lines, out, blanks = text.split("\n"), [], 0
    for line in lines:
        if line.strip():
            blanks = 0
            out.append(line.rstrip())
        elif blanks < 1:
            blanks += 1
            out.append("")
    return "\n".join(out).strip() + "\n"


def extract(html: str, base_url: str = "", main_only: bool = True) -> dict:
    """Return {title, markdown, links} from an HTML document."""
    root = parse_html(html)
    title = extract_title(root)
    links = extract_links(root, base_url) if base_url else []
    body = main_content(root) if main_only else root
    markdown = _collapse_blanks(_render_children(body))
    return {"title": title, "markdown": markdown, "links": links}
