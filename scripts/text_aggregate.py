#!/usr/bin/env python3
"""
Aggregate OCR/translation text from *_translations.txt dumps into
unique text lists and dictionary templates for consistency editing.

Input sources:
  - A single file created by running MIT with --save-text-file <path>
  - One or more *_translations.txt files (default naming per image)

Outputs (under --out-dir, default: aggregated):
  - raw_records.json      Structured dump of all parsed entries
  - unique_lines.txt      Unique source lines, frequency-sorted
  - template_pre_dict.txt    Regex->replacement skeleton for pre-translation fixes
  - template_post_dict.txt   Regex->replacement skeleton for post-translation fixes

Usage examples:
  python scripts/text_aggregate.py --in chapter_128_text.txt
  python scripts/text_aggregate.py --in samples_in/*_translations.txt --out-dir aggregated
"""

from __future__ import annotations

import argparse
import json
import os
import re
from collections import Counter
from pathlib import Path
from typing import Iterable


def parse_records(paths: Iterable[Path]):
    records = []
    header_re = re.compile(r"^\[(?P<path>.*)\]\s*$")
    cur = None
    for p in paths:
        try:
            text = Path(p).read_text(encoding="utf-8", errors="ignore")
        except Exception as e:
            print(f"[warn] failed to read {p}: {e}")
            continue
        for line in text.splitlines():
            line = line.rstrip("\n")
            if not line:
                continue
            m = header_re.match(line)
            if m:
                if cur:
                    records.append(cur)
                cur = {
                    "image_path": m.group("path"),
                    "items": [],
                }
                continue
            if cur is None:
                # Skip lines before first header
                continue
            # Block boundaries like "-- 1 --"
            if line.startswith("-- "):
                cur["items"].append({})
                continue
            if not cur["items"]:
                cur["items"].append({})
            item = cur["items"][-1]
            if line.startswith("color: "):
                item["color"] = line[len("color: "):].strip()
            elif line.startswith("text: "):
                item["text"] = line[len("text: "):].strip()
            elif line.startswith("trans: "):
                item["trans"] = line[len("trans: "):].strip()
            elif line.startswith("coords: "):
                item["coords"] = line[len("coords: "):].strip()
        if cur:
            records.append(cur)
            cur = None
    return records


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def write_outputs(records, out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "raw_records.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    # Collect unique source lines
    texts = [normalize(it.get("text", ""))
             for rec in records for it in rec.get("items", []) if it.get("text")]
    counter = Counter(t for t in texts if t)
    unique_sorted = sorted(counter.items(), key=lambda x: (-x[1], x[0]))
    with (out_dir / "unique_lines.txt").open("w", encoding="utf-8") as f:
        for t, c in unique_sorted:
            f.write(f"{c}\t{t}\n")

    # Dictionary templates
    pre_tpl = (
        "# Pre-translation dictionary\n"
        "# Format: <regex> <replacement>\n"
        "# Applied BEFORE translation. Good for normalizing OCR quirks and names.\n"
        "# Examples:\n"
        "#   뉴스테이블\s* News Table\n"
        "#   A\\.I\\. AI\n"
        "#   수혁이 Su-hyeok\n"
        "\n"
    )
    (out_dir / "template_pre_dict.txt").write_text(pre_tpl, encoding="utf-8")

    post_tpl = (
        "# Post-translation dictionary\n"
        "# Format: <regex> <replacement>\n"
        "# Applied AFTER translation. Good for enforcing preferred English phrasing.\n"
        "# Examples:\n"
        "#   National broadcaster KBS\n"
        "#   medical institution hospital\n"
        "\n"
    )
    (out_dir / "template_post_dict.txt").write_text(post_tpl, encoding="utf-8")

    print(f"[ok] wrote {out_dir}/raw_records.json")
    print(f"[ok] wrote {out_dir}/unique_lines.txt  (freq\ttext)")
    print(f"[ok] wrote {out_dir}/template_pre_dict.txt")
    print(f"[ok] wrote {out_dir}/template_post_dict.txt")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Aggregate extracted text and build dictionary templates")
    ap.add_argument("--in", dest="inputs", nargs="+", required=True,
                    help="Input text dumps (e.g., chapter_128_text.txt or *_translations.txt)")
    ap.add_argument("--out-dir", default="aggregated", help="Output directory")
    args = ap.parse_args(argv)

    paths = [Path(p) for p in args.inputs]
    records = parse_records(paths)
    write_outputs(records, Path(args.out_dir))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

