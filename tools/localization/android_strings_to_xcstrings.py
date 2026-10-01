#!/usr/bin/env python3
"""Builds App/Resources/Localizable.xcstrings from the Android app's string resources.

Usage (from the repo root):
    python tools/localization/android_strings_to_xcstrings.py <android res dir>
    e.g. python tools/localization/android_strings_to_xcstrings.py \
        "../PixelPlayer-master/beta2-release/app/src/main/res"

What it does
  1. Collects every string the iOS app looks up:
       - `String(localized: "<android_key>", defaultValue: "<English>")` (the L10n tables) — keyed by Android key;
       - English literals passed to SwiftUI as `LocalizedStringKey` (`Text("…")`, `Button("…")`, `Label("…", …)`,
         `Toggle("…", …)`, `Section("…")`, `.navigationTitle("…")`) — keyed by the English text.
  2. Reads Android's `values/strings*.xml` (English) and the 11 translated locales (`values-ar`, `-de`, `-es`, `-fr`,
     `-in`, `-it`, `-ko`, `-nb`, `-ru`, `-tr`, `-zh-rCN`).
  3. A translation is used only when the iOS English equals Android's English (after the PixelPlayer → PixlAudio
     rename and placeholder conversion) — a string whose meaning changed on iOS stays English rather than show a
     wrong translation — and only when the translation's placeholders match the English ones.
  4. Converts placeholders: `%s` / `%1$s` → `%@` / `%1$@`, `%d` / `%1$d` → `%lld` / `%1$lld` (Swift passes Int);
     non-positional placeholders become positional when the English is positional. Android escapes (`\\'`, `\\"`,
     `\\n`, `\\t`, `\\@`, `\\?`) are unescaped; a string wrapped in double quotes loses them.
  5. Writes the String Catalog (sorted keys, `extractionState: manual`), with the English value for every key.

Re-run it whenever iOS strings or the Android translations change; never hand-edit the catalog.
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(REPO, "App")
OUT = os.path.join(APP, "Resources", "Localizable.xcstrings")

LOCALES = {"ar": "ar", "de": "de", "es": "es", "fr": "fr", "in": "id", "it": "it", "ko": "ko", "nb": "nb",
           "ru": "ru", "tr": "tr", "zh-rCN": "zh-Hans"}

BRAND = [("PixelPlayer", "PixlAudio"), ("Pixel Player", "PixlAudio"), ("PixelPlay", "PixlAudio")]

# Swift string literal body (no unescaped quote).
LIT = r'"((?:[^"\\\n]|\\.)*)"'
LOCALIZED_RE = re.compile(r'String\(localized:\s*' + LIT + r'\s*,\s*defaultValue:\s*' + LIT)
LITERAL_RE = re.compile(r'(?<![\w.])(?:Text|Button|Label|Toggle|Section|navigationTitle)\(\s*' + LIT)
PLACEHOLDER_RE = re.compile(r'%(?:(\d+)\$)?(\.?\d*)(lld|ld|d|s|@|f)')


def swift_unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "'": "'", "\\": "\\", "0": "\0"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def collect_ios_strings():
    localized, literals = {}, set()
    for root, _, files in os.walk(APP):
        for name in files:
            if not name.endswith(".swift"):
                continue
            text = open(os.path.join(root, name), encoding="utf-8").read()
            for key, value in LOCALIZED_RE.findall(text):
                localized.setdefault(swift_unescape(key), swift_unescape(value))
            for value in LITERAL_RE.findall(text):
                if "\\(" in value or "%" in value:
                    continue  # interpolated or format text: not a plain key
                literal = swift_unescape(value)
                if re.search(r"[A-Za-z]{2}", literal) and not re.fullmatch(r"[a-z0-9]+(\.[a-z0-9.]+)+", literal):
                    literals.add(literal)  # skip SF Symbol names such as "forward.end.fill"
    return localized, literals


def android_unescape(raw):
    s = raw.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def read_strings(directory):
    table = {}
    if not os.path.isdir(directory):
        return table
    for name in sorted(os.listdir(directory)):
        if not (name.startswith("strings") and name.endswith(".xml")):
            continue
        try:
            root = ET.parse(os.path.join(directory, name)).getroot()
        except ET.ParseError as error:
            print(f"warning: {directory}/{name}: {error}", file=sys.stderr)
            continue
        for element in root.findall("string"):
            if element.get("translatable") == "false":
                continue
            key = element.get("name")
            table[key] = android_unescape("".join(element.itertext()))
    return table


def convert_placeholders(text, positional):
    counter = [0]

    def repl(m):
        index, precision, kind = m.group(1), m.group(2), m.group(3)
        counter[0] += 1
        if kind in ("s", "@"):
            kind = "@"
        elif kind in ("d", "ld", "lld"):
            kind = "lld"
        if index is None and positional:
            index = str(counter[0])
        return "%" + (index + "$" if index else "") + precision + kind

    return PLACEHOLDER_RE.sub(repl, text)


def placeholders(text):
    found = []
    for i, m in enumerate(PLACEHOLDER_RE.finditer(text)):
        found.append((m.group(1) or str(i + 1), m.group(3)))
    return sorted(found)


def normalize(text):
    for old, new in BRAND:
        text = text.replace(old, new)
    return text


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    res = sys.argv[1]
    english = {k: normalize(v) for k, v in read_strings(os.path.join(res, "values")).items()}
    translations = {code: read_strings(os.path.join(res, "values-" + folder)) for folder, code in LOCALES.items()}
    localized, literals = collect_ios_strings()

    by_english = {}
    for key in sorted(english):
        by_english.setdefault(convert_placeholders(english[key], True), key)

    catalog, translated_keys, untranslated = {}, 0, 0

    def entry(ios_english, android_key):
        nonlocal translated_keys, untranslated
        units = {"en": {"stringUnit": {"state": "translated", "value": ios_english}}}
        positional = bool(re.search(r"%\d+\$", ios_english))
        if android_key is not None:
            expected = placeholders(ios_english)
            for code, table in translations.items():
                raw = table.get(android_key)
                if raw is None:
                    continue
                value = convert_placeholders(normalize(raw), positional)
                if placeholders(value) != expected or not value.strip():
                    continue
                units[code] = {"stringUnit": {"state": "translated", "value": value}}
        if len(units) > 1:
            translated_keys += 1
        else:
            untranslated += 1
        return {"extractionState": "manual", "localizations": units}

    for key, value in sorted(localized.items()):
        android = english.get(key)
        same = android is not None and convert_placeholders(android, bool(re.search(r"%\d+\$", value))) == value
        catalog[key] = entry(value, key if same else None)
    for literal in sorted(literals):
        if literal in catalog:
            continue
        catalog[literal] = entry(literal, by_english.get(literal))

    document = {"sourceLanguage": "en", "strings": dict(sorted(catalog.items())), "version": "1.0"}
    with open(OUT, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=2, separators=(",", " : "))
        handle.write("\n")
    print(f"{len(catalog)} strings ({len(localized)} keyed, {len(catalog) - len(localized)} literal): "
          f"{translated_keys} translated, {untranslated} English only -> {os.path.relpath(OUT, REPO)}")


if __name__ == "__main__":
    main()
