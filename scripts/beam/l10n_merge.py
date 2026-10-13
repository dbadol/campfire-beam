#!/usr/bin/env python3
"""Merge ARB fragments into lib/l10n/app_en.arb, checking every message.

Several people (or workers) extracting text at once each write their keys to
their own fragment, lib/l10n/parts/<area>.arb (a JSON object of "key" and
"@key" pairs, no "@@locale"), so nobody edits app_en.arb at the same time.
This script folds the fragments into app_en.arb, sorted by key (keys carry
their area as a prefix, so an area's messages stay together), and refuses:

  * a key that is not lowerCamelCase;
  * a message with no "@key" description (translators rely on them);
  * an empty message;
  * a {placeholder} used but not declared, or declared but not used;
  * a placeholder typed other than String, int or DateTime, or carrying a
    "format" (numbers are never formatted by the locale: amounts arrive as
    ready-made strings, counts as plain integers);
  * the same key twice with different text.

  scripts/beam/l10n_merge.py                 # check fragments + app_en.arb, write nothing
  scripts/beam/l10n_merge.py --write         # merge into app_en.arb
  scripts/beam/l10n_merge.py --write --consume   # ... and delete the merged fragments
  scripts/beam/l10n_merge.py --write --consume --only dex.arb names.arb
        # fold in just these fragments (the others stay where they are)
  scripts/beam/l10n_merge.py --root DIR --write --lenient
        # merge into DIR's copy, skipping (with a warning) a fragment that is
        # not valid JSON yet (someone is mid-edit)
"""

import argparse
import json
import os
import re
import sys
from collections import OrderedDict

KEY_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")
TYPES = {"String", "int", "DateTime"}


def placeholders_used(message):
    """Names of {placeholders} in an ICU message, including plural/select
    selectors ({count, plural, one{...} other{...}}) and the placeholders
    inside their cases."""
    names = set()

    def skip_ws(i):
        while i < len(message) and message[i].isspace():
            i += 1
        return i

    def ident(i):
        m = re.match(r"=?[A-Za-z0-9_]+", message[i:])
        return (m.group(0), i + len(m.group(0))) if m else (None, i)

    def text(i, nested):
        # Plain text up to the end, or up to the "}" closing a case body.
        while i < len(message):
            c = message[i]
            if c == "{":
                i = argument(i + 1)
            elif c == "}" and nested:
                return i + 1
            else:
                i += 1
        return i

    def argument(i):
        i = skip_ws(i)
        name, i = ident(i)
        if name:
            names.add(name)
        i = skip_ws(i)
        if i < len(message) and message[i] == "}":
            return i + 1
        if i < len(message) and message[i] == ",":
            _, i = ident(skip_ws(i + 1))  # plural / select / ...
            i = skip_ws(i)
            if i < len(message) and message[i] == ",":
                i += 1
            while True:
                i = skip_ws(i)
                if i >= len(message) or message[i] == "}":
                    return i + 1
                _, i = ident(i)  # one / other / =1
                i = skip_ws(i)
                if i < len(message) and message[i] == "{":
                    i = text(i + 1, True)
                else:
                    return i
        return i

    text(0, False)
    return names


def check_entries(entries, origin, errors):
    for key, value in entries.items():
        if key.startswith("@@"):
            continue
        if key.startswith("@"):
            base = key[1:]
            if base not in entries:
                errors.append(f"{origin}: {key} describes no message")
            continue
        if not KEY_RE.match(key):
            errors.append(f"{origin}: key {key!r} is not lowerCamelCase")
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{origin}: {key} is empty")
            continue
        meta = entries.get("@" + key)
        if not isinstance(meta, dict) or not str(meta.get("description", "")).strip():
            errors.append(f"{origin}: {key} has no @{key} description")
            continue
        declared = meta.get("placeholders", {}) or {}
        used = placeholders_used(value)
        for name in sorted(used - set(declared)):
            errors.append(f"{origin}: {key} uses {{{name}}} but @{key} does not declare it")
        for name in sorted(set(declared) - used):
            errors.append(f"{origin}: {key} declares {name} but does not use it")
        for name, spec in declared.items():
            spec = spec or {}
            t = spec.get("type")
            if t not in TYPES:
                errors.append(f"{origin}: {key}.{name} has type {t!r} (use String or int)")
            if "format" in spec:
                errors.append(f"{origin}: {key}.{name} has a format: pass a ready-made string")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--consume", action="store_true")
    ap.add_argument("--lenient", action="store_true")
    ap.add_argument("--only", nargs="+", metavar="FRAGMENT")
    args = ap.parse_args()

    l10n = os.path.join(args.root, "lib", "l10n")
    en_path = os.path.join(l10n, "app_en.arb")
    parts_dir = os.path.join(l10n, "parts")
    errors = []

    with open(en_path, encoding="utf-8") as f:
        base = json.load(f, object_pairs_hook=OrderedDict)
    check_entries(base, "app_en.arb", errors)

    merged = OrderedDict((k, v) for k, v in base.items() if not k.startswith("@@"))
    consumed = []
    if os.path.isdir(parts_dir):
        for name in sorted(os.listdir(parts_dir)):
            if not name.endswith(".arb"):
                continue
            if args.only and name not in args.only:
                continue
            path = os.path.join(parts_dir, name)
            try:
                with open(path, encoding="utf-8") as f:
                    part = json.load(f, object_pairs_hook=OrderedDict)
            except (OSError, ValueError) as e:
                msg = f"parts/{name}: not valid JSON ({e})"
                if args.lenient:
                    print("warning: " + msg + ", skipped", file=sys.stderr)
                    continue
                errors.append(msg)
                continue
            if "@@locale" in part:
                errors.append(f"parts/{name}: a fragment has no @@locale")
            part_errors = []
            check_entries(part, f"parts/{name}", part_errors)
            if part_errors and args.lenient:
                for e in part_errors:
                    print("warning: " + e, file=sys.stderr)
            else:
                errors.extend(part_errors)
            for key, value in part.items():
                if key.startswith("@@"):
                    continue
                if key in merged and merged[key] != value:
                    if key.startswith("@"):
                        errors.append(f"parts/{name}: {key} differs from an earlier definition")
                    else:
                        errors.append(
                            f"parts/{name}: {key} already exists with other text: "
                            f"{merged[key]!r} vs {value!r}"
                        )
                    continue
                merged[key] = value
            consumed.append(path)

    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"{len(errors)} problem(s)", file=sys.stderr)
        return 1

    messages = sorted(k for k in merged if not k.startswith("@"))
    out = OrderedDict([("@@locale", "en")])
    for k in messages:
        out[k] = merged[k]
        out["@" + k] = merged["@" + k]
    print(f"app_en.arb: {len(messages)} messages ({len(consumed)} fragment(s))")
    if args.write:
        with open(en_path, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
            f.write("\n")
        if args.consume:
            for p in consumed:
                os.remove(p)
            if os.path.isdir(parts_dir) and not os.listdir(parts_dir):
                os.rmdir(parts_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
