"""iOS 15 ToolbarContentBuilder has no `if`: move each condition inside the toolbar items instead."""
import re


def _skip_string(text, i):
    """i points at an opening quote; returns the index just after the string literal."""
    i += 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == '"':
            return i + 1
        i += 1
    return i


def matching(text, open_index, open_char, close_char):
    """Index just after the bracket matching the one at open_index (strings and // comments skipped)."""
    depth = 0
    i = open_index
    while i < len(text):
        ch = text[i]
        if ch == '"':
            i = _skip_string(text, i)
            continue
        if text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if ch == open_char:
            depth += 1
        elif ch == close_char:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced brackets")


ITEM = re.compile(r"ToolbarItem(?:Group)?\(")
IF_LINE = re.compile(r"(?m)^[ \t]*if ")


def _rewrite_body(body):
    out = []
    i = 0
    changed = False
    while i < len(body):
        match = IF_LINE.search(body, i)
        if not match:
            out.append(body[i:])
            break
        depth = 0
        for ch in body[:match.start()]:
            depth += (ch == "{") - (ch == "}")
        if depth != 0:
            line_end = body.find("\n", match.start())
            line_end = len(body) if line_end < 0 else line_end + 1
            out.append(body[i:line_end])
            i = line_end
            continue
        header_start = match.end()
        brace = header_start
        paren = 0
        while brace < len(body):
            ch = body[brace]
            if ch == "(":
                paren += 1
            elif ch == ")":
                paren -= 1
            elif ch == "{" and paren == 0:
                break
            brace += 1
        condition = body[header_start:brace].strip()
        if_end = matching(body, brace, "{", "}")
        inner = body[brace + 1: if_end - 1]
        if re.match(r"\s*else", body[if_end:]):
            # if/else (e.g. the macOS-only main window): leave untouched
            out.append(body[i:if_end])
            i = if_end
            continue
        items = []
        j = 0
        while j < len(inner):
            item = ITEM.search(inner, j)
            if not item:
                break
            args_end = matching(inner, item.end() - 1, "(", ")")
            body_open = inner.index("{", args_end)
            body_end = matching(inner, body_open, "{", "}")
            header = inner[item.start():body_open]
            content = inner[body_open + 1: body_end - 1]
            items.append(header + "{\n if " + condition + " {" + content + "}\n }")
            j = body_end
        assert items, "toolbar if without items"
        out.append(body[i:match.start()])
        out.append("\n".join(items) + "\n")
        i = if_end
        changed = True
    return "".join(out), changed


def fix_toolbar_ifs(text):
    search_from = 0
    while True:
        start = text.find(".toolbar {", search_from)
        if start < 0:
            return text
        open_index = text.index("{", start)
        close = matching(text, open_index, "{", "}")
        new_body, changed = _rewrite_body(text[open_index + 1: close - 1])
        if changed:
            text = text[: open_index + 1] + new_body + text[close - 1:]
            close = open_index + 1 + len(new_body) + 1
        search_from = close
