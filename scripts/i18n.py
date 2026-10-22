#!/usr/bin/env python3
"""Translations for the Mac app.

  scripts/i18n.py extract   find every UI text in mac/ (and the engine's progress messages),
                            add new ones to mac/Localization/<lang>.json, report what's missing
  scripts/i18n.py build OUT write OUT/<lang>.lproj/Localizable.strings (used by build_app.sh)

Keys are the English texts. Placeholders: %@ (any value, in order) — e.g. "%@ to-dos".
To add a language: copy en.json to <code>.json, translate the values, and add the code to
AppLanguage.supported in mac/App/Localization.swift. An empty value means "not translated yet"
(English is shown).
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOC = ROOT / "mac" / "Localization"
LANGS = ["en", "fr", "es", "pt", "ja", "zh-Hans"]

STR = r'"((?:[^"\\]|\\.)*)"'
SWIFT_PATTERNS = [
    # SwiftUI views that localize a literal title, and our own helpers.
    rf'\b(?:Text|Button|Label|Toggle|Picker|Section|TextField|LabeledContent|Menu|Link|ProgressView|'
    rf'confirmationDialog|Caption|tr|i18n|show|permissionRow|notify|bullets|UpdateError|notice|onNotice\?|permission|point|title|other)\(\s*{STR}',
    rf'\.help\(\s*{STR}',
    rf'\b(?:text|title|label|body|message|prompt|detail|subtitle):\s*(?:Text\()?{STR}',
]
PY_PATTERN = rf'(?:\bstep\(\s*|"key":\s*){STR}'


def extract_keys() -> tuple[set[str], list[str]]:
    keys, problems = set(), []
    for path in sorted(p for p in (ROOT / "mac").rglob("*.swift") if p.name not in ("RecorderCLI.swift", "Uninstall.swift")):
        text = path.read_text()
        for pattern in SWIFT_PATTERNS:
            for m in re.finditer(pattern, text):
                s = m.group(1)
                if not s or not re.search(r"[A-Za-z]", s) or re.fullmatch(r"[a-z0-9_\-]+(\.[a-z0-9_\-]+)+", s):
                    continue  # empty, symbols only, or an identifier like "meetscribe.system-audio"
                if s.startswith("\\(Image"):
                    continue  # icon + value (menu bar), nothing to translate
                if "\\(" in s:
                    line = text[: m.start()].count("\n") + 1
                    problems.append(f"{path.name}:{line}: interpolation in a translatable text: \"{s}\"")
                    continue
                keys.add(s.encode().decode("unicode_escape") if "\\u" in s else s.replace('\\"', '"'))
    for path in sorted((ROOT / "src").rglob("*.py")):
        for m in re.finditer(PY_PATTERN, path.read_text()):
            keys.add(m.group(1))
    return keys, problems


def load(lang: str) -> dict:
    p = LOC / f"{lang}.json"
    return json.loads(p.read_text()) if p.exists() else {}


def save(lang: str, data: dict) -> None:
    LOC.mkdir(parents=True, exist_ok=True)
    (LOC / f"{lang}.json").write_text(json.dumps(dict(sorted(data.items(), key=lambda kv: kv[0].lower())),
                                                  ensure_ascii=False, indent=1) + "\n")


def extract() -> int:
    keys, problems = extract_keys()
    for lang in LANGS:
        data = load(lang)
        for k in keys:
            data.setdefault(k, k if lang == "en" else "")
        unused = [k for k in data if k not in keys]
        for k in unused:
            del data[k]
        save(lang, data)
        missing = sum(1 for k in keys if not data.get(k))
        print(f"{lang:8} {len(keys)} texts, {missing} not translated" + (f", {len(unused)} removed" if unused else ""))
    for p in problems:
        print("⚠️ ", p)
    return 1 if problems else 0


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def build(out: Path) -> None:
    for lang in LANGS:
        data = load(lang)
        d = out / f"{lang}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        lines = [f'"{escape(k)}" = "{escape(v)}";' for k, v in data.items() if v]
        (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "extract":
        sys.exit(extract())
    if len(sys.argv) >= 3 and sys.argv[1] == "build":
        build(Path(sys.argv[2]))
        sys.exit(0)
    print(__doc__)
    sys.exit(2)
