#!/usr/bin/env python3
"""
Build per-image translation JSON arrays from unique_lines.txt and unique_lines_EN.txt.

Inputs (default locations):
  aggregated/<chapter>/unique_lines.txt      # freq\ttext
  aggregated/<chapter>/unique_lines_EN.txt   # translated text, one per source line
  aggregated/<chapter>/raw_records.json      # structured per-image OCR records

Outputs:
  aggregated/<chapter>/llm/<image_basename>_translations.json  # JSON array aligned to text regions

Usage:
  python scripts/llm_translate_mapping.py --chapter naver_765804_127_AI
  # or specify explicit files
  python scripts/llm_translate_mapping.py --src unique_lines.txt --dst unique_lines_EN.txt --records raw_records.json --out-dir aggregated/<chapter>/llm
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Dict, List


def load_unique_pairs(src_path: Path, dst_path: Path) -> Dict[str, str]:
    src_lines = []
    with src_path.open('r', encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            # Expect: freq\ttext; take the text part
            parts = line.split('\t', 1)
            text = parts[1] if len(parts) > 1 else parts[0]
            src_lines.append(text.strip())
    with dst_path.open('r', encoding='utf-8') as f:
        en_lines = [l.rstrip('\n') for l in f]
    if len(src_lines) != len(en_lines):
        # Be forgiving: pad or truncate EN to match source, but warn loudly
        print(f"[warn] Line count mismatch: {src_path}={len(src_lines)} vs {dst_path}={len(en_lines)}")
        if len(en_lines) < len(src_lines):
            en_lines += [''] * (len(src_lines) - len(en_lines))
            print(f"[warn] Padded EN with {len(src_lines) - len(en_lines)} empty lines to align.")
        elif len(en_lines) > len(src_lines):
            en_lines = en_lines[:len(src_lines)]
            print(f"[warn] Truncated EN to {len(src_lines)} lines to align.")
    return {s: t for s, t in zip(src_lines, en_lines)}


def normalize(s: str) -> str:
    # Keep simple normalization; upstream comparisons are literal
    return re.sub(r"\s+", " ", s.strip())


def build_per_image(records_path: Path, mapping: Dict[str, str]) -> Dict[str, List[str]]:
    data = json.loads(records_path.read_text(encoding='utf-8'))
    per_image: Dict[str, List[str]] = {}
    for rec in data:
        img_path = rec.get('image_path') or rec.get('image') or ''
        base = Path(img_path).name
        out: List[str] = []
        for item in rec.get('items', []):
            src = normalize(item.get('text', '') or '')
            if not src:
                out.append('')
                continue
            en = mapping.get(src, '')
            out.append(en)
        per_image[base] = out
    return per_image


def write_outputs(per_image: Dict[str, List[str]], out_dir: Path):
    out_dir.mkdir(parents=True, exist_ok=True)
    for base, arr in per_image.items():
        stem = Path(base).stem
        p = out_dir / f"{stem}_translations.json"
        p.write_text(json.dumps(arr, ensure_ascii=False, indent=2), encoding='utf-8')


def main(argv=None):
    ap = argparse.ArgumentParser(description='Build per-image translation JSON arrays from LLM outputs')
    ap.add_argument('--chapter', help='Chapter label under aggregated/')
    ap.add_argument('--src', help='Path to unique_lines.txt')
    ap.add_argument('--dst', help='Path to unique_lines_EN.txt')
    ap.add_argument('--records', help='Path to raw_records.json')
    ap.add_argument('--out-dir', help='Output dir for per-image JSON arrays')
    args = ap.parse_args(argv)

    if args.chapter:
        base = Path('aggregated') / args.chapter
        src = Path(args.src) if args.src else base / 'unique_lines.txt'
        dst = Path(args.dst) if args.dst else base / 'unique_lines_EN.txt'
        records = Path(args.records) if args.records else base / 'raw_records.json'
        out_dir = Path(args.out_dir) if args.out_dir else base / 'llm'
    else:
        if not (args.src and args.dst and args.records and args.out_dir):
            ap.error('Either --chapter or all of --src, --dst, --records, --out-dir must be provided')
        src = Path(args.src)
        dst = Path(args.dst)
        records = Path(args.records)
        out_dir = Path(args.out_dir)

    mapping = load_unique_pairs(src, dst)
    per_image = build_per_image(records, mapping)
    write_outputs(per_image, out_dir)
    print(f"[ok] wrote per-image translations to {out_dir}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
