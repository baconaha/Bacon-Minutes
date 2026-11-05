#!/usr/bin/env python3
"""Checks App/Resources/<lang>.lproj/Localizable.strings against the L("…") keys in the Swift code.

Fails when a key used in code is missing from a language, when a translation drops or adds a
{0}-style placeholder, or when a .strings file does not parse. Unused entries are only reported.

    python3 tools/check_l10n.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGS = ["en", "ja", "ko", "es", "vi", "fr", "pt", "ru"]
# Keys passed to L() indirectly (ProviderPreset names).
EXTRA_KEYS = ["阿里云百炼（通义）", "月之暗面 Kimi", "智谱 GLM", "百度千帆（文心）", "腾讯混元", "火山方舟（豆包）", "硅基流动", "Ollama（本地）", "LM Studio（本地）", "自定义"]

CALL = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"\{\d+\}")


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def code_keys():
    keys = set(EXTRA_KEYS)
    for path in list((ROOT / "App/Sources").rglob("*.swift")) + list((ROOT / "Sources").rglob("*.swift")):
        for m in CALL.finditer(path.read_text(encoding="utf-8")):
            keys.add(unescape(m.group(1)))
    return keys


ENTRY = re.compile(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def parse_strings(path):
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    table, pos = {}, 0
    while True:
        m = ENTRY.match(text, pos)
        if not m:
            if text[pos:].strip():
                raise ValueError("%s: cannot parse near %r" % (path, text[pos:pos + 80]))
            return table
        k, v = unescape(m.group(1)), unescape(m.group(2))
        if k in table:
            raise ValueError("%s: duplicate key %r" % (path, k))
        table[k] = v
        pos = m.end()


def main():
    keys = code_keys()
    errors = 0
    for lang in LANGS:
        path = ROOT / "App/Resources" / (lang + ".lproj") / "Localizable.strings"
        try:
            table = parse_strings(path)
        except (OSError, ValueError) as e:
            print("error:", e)
            errors += 1
            continue
        for k in sorted(keys - table.keys()):
            print("error: %s missing %r" % (lang, k))
            errors += 1
        for k, v in table.items():
            if sorted(PLACEHOLDER.findall(k)) != sorted(PLACEHOLDER.findall(v)):
                print("error: %s placeholders differ for %r -> %r" % (lang, k, v))
                errors += 1
        for k in sorted(table.keys() - keys):
            print("note: %s has unused %r" % (lang, k))
    print("%d keys, %d languages, %d errors" % (len(keys), len(LANGS), errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
