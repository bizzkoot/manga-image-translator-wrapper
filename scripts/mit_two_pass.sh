#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

# Defaults
CHAPTER=""
INPUT_DIR=""
RENDER_ONLY=false
EXTRACT_ONLY=false
LIMIT_IMAGES=

usage() {
  cat <<USAGE
Usage: bash scripts/mit_two_pass.sh [options]

Runs a two-pass pipeline over images in samples_in/:
  1) Extract-only pass to dump text per image (fast, no inpainting/MT)
  2) Aggregate unique lines and create dictionary templates
  3) Translate + render with dictionaries for consistency

Options:
  --chapter NAME     Label outputs under aggregated/NAME (default: timestamp)
  --input DIR        Input folder (default: from scripts/mit_mac.env or ./samples_in)
  --extract-only     Run extraction + aggregation only (skip render)
  --render-only      Skip extraction; aggregate if needed and then render
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chapter) CHAPTER="${2:-}"; shift 2 ;;
    --input) INPUT_DIR="${2:-}"; shift 2 ;;
    --extract-only) EXTRACT_ONLY=true; shift ;;
    --render-only) RENDER_ONLY=true; shift ;;
    --limit) LIMIT_IMAGES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Preserve CLI-provided values before loading env
CLI_PROVIDED_INPUT_DIR="$INPUT_DIR"
CLI_PROVIDED_CHAPTER="$CHAPTER"

# Load env defaults
if [[ -f "$here/mit_mac.env" ]]; then
  # shellcheck disable=SC1091
  source "$here/mit_mac.env"
fi

# Restore CLI-provided values if present (env should not clobber)
if [[ -n "$CLI_PROVIDED_INPUT_DIR" ]]; then INPUT_DIR="$CLI_PROVIDED_INPUT_DIR"; fi
if [[ -n "$CLI_PROVIDED_CHAPTER" ]]; then CHAPTER="$CLI_PROVIDED_CHAPTER"; fi

# Finalize defaults
INPUT_DIR="${INPUT_DIR:-./samples_in}"
OUTPUT_DIR="${OUTPUT_DIR:-./samples_out}"

ts="$(date +%Y%m%d-%H%M%S)"
# Derive CHAPTER if not provided: try .chapter.json label or folder basename
if [[ -z "$CHAPTER" ]]; then
  if [[ -f "$INPUT_DIR/.chapter.json" ]]; then
    CHAPTER="$(python - "$INPUT_DIR" <<'PY'
import json,sys,os
p=sys.argv[1]
try:
  with open(os.path.join(p,'.chapter.json'),encoding='utf-8') as f:
    data=json.load(f)
  print(data.get('label','').strip())
except Exception:
  pass
PY
)"
  fi
  if [[ -z "$CHAPTER" ]]; then
    CHAPTER="$(basename "$INPUT_DIR")"
  fi
fi
CHAPTER="${CHAPTER:-$ts}"
AGG_DIR="aggregated/$CHAPTER"
DICT_DIR="dicts"
mkdir -p "$AGG_DIR" "$DICT_DIR"

# Build an input subset when --limit is provided
RUN_INPUT_DIR="$INPUT_DIR"
if [[ -n "${LIMIT_IMAGES}" ]]; then
  echo "[debug] Limiting to first ${LIMIT_IMAGES} images"
  SUBSET_DIR=".cache/subsets/${CHAPTER}-${LIMIT_IMAGES}"
  rm -rf "$SUBSET_DIR" 2>/dev/null || true
  mkdir -p "$SUBSET_DIR"
  mapfile -t SEL < <(find "$INPUT_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) | sort | head -n "$LIMIT_IMAGES")
  if (( ${#SEL[@]} == 0 )); then
    echo "[warn] No images found in $INPUT_DIR" >&2
  else
    for f in "${SEL[@]}"; do
      cp "$f" "$SUBSET_DIR/" 2>/dev/null || true
    done
    RUN_INPUT_DIR="$SUBSET_DIR"
  fi
fi

echo "[1/3] Extract pass (translator none, original inpaint)"
if [[ "$RENDER_ONLY" != true ]]; then
  # Write extract images to a per-chapter folder for tidier debugging
  EXTRACT_OUTPUT_BASE="${EXTRACT_OUTPUT_DIR:-./samples_out_extract}"
  EXTRACT_OUTPUT_DIR="$EXTRACT_OUTPUT_BASE/$CHAPTER"
  CONFIG_PATH="$here/mit_config_extract.json" \
  CLI_INPUT_DIR="$RUN_INPUT_DIR" \
  OUTPUT_DIR="$EXTRACT_OUTPUT_DIR" \
  EXTRA_FLAGS="--prep-manual --skip-no-text --overwrite" \
  bash "$here/mit_run.sh" --use-gpu-limited -v
else
  echo "  Skipped (render-only)"
fi

echo "[2/3] Aggregate text dumps"
# Collect per-image dumps from the processed set: <image>_translations.txt
mapfile -t TEXT_FILES < <(find "$RUN_INPUT_DIR" -type f -name "*_translations.txt" | sort)
  if (( ${#TEXT_FILES[@]} == 0 )); then
    echo "  No text dumps found under $RUN_INPUT_DIR. Ensure extract pass completed and images had detectable text." >&2
  else
    python "$here/text_aggregate.py" --in "${TEXT_FILES[@]}" --out-dir "$AGG_DIR"
  fi

# Optional: prepare Qwen CLI prompt/input for high-quality translation
UNIQUE_SRC="$AGG_DIR/unique_lines.txt"
UNIQUE_DST="$AGG_DIR/unique_lines_EN.txt"
QWEN_INPUT="$AGG_DIR/qwen_input.txt"
if [[ -f "$UNIQUE_SRC" ]]; then
  echo "[info] Building Qwen input at $QWEN_INPUT"
  {
    echo "You are a professional comic translator. Translate the following source lines (one per line) to natural, coherent English as if part of the same episode."
    echo "Requirements:"
    echo "- Output exactly one line per input line, same order and count."
    echo "- No numbering, no extra commentary, no quotes around lines."
    echo "- Make the lines flow naturally across the list, consistent tone and terminology."
    echo "- Keep punctuation appropriate for English dialogue."
    echo
    echo "=== SOURCE LINES (do not repeat header) ==="
    awk -F "\t" '{ $1=""; sub(/^\t/, ""); print }' "$UNIQUE_SRC"
  } > "$QWEN_INPUT"

  SKIP_LLM=""
  if [[ -f "$UNIQUE_DST" ]]; then
    echo "[info] Found existing LLM translation file: $UNIQUE_DST"
    echo "Options: [u]se as-is, [r]eplace file, re[d]o from scratch, [f]allback (ignore LLM)"
    read -r -p "Choose [u/r/d/f] (default u): " choice
    case "${choice:-u}" in
      r|R)
        echo "- Replace: provide a path to a new EN file (or leave empty to edit current)"
        read -r -p "Path to replacement (blank to edit current): " repl
        if [[ -n "$repl" && -f "$repl" ]]; then
          cp -f "$repl" "$UNIQUE_DST"
          echo "[ok] Replaced $UNIQUE_DST"
        else
          ${EDITOR:-nano} "$UNIQUE_DST" || true
        fi
        ;;
      d|D)
        echo "- Redo: removing previous EN + mappings"
        rm -f "$UNIQUE_DST" 2>/dev/null || true
        rm -rf "$AGG_DIR/llm" 2>/dev/null || true
        ;;
      f|F)
        echo "- Fallback: will ignore external LLM translations"
        SKIP_LLM=1
        ;;
      *)
        echo "- Use as-is"
        ;;
    esac
  fi

  if [[ -z "$SKIP_LLM" && ! -f "$UNIQUE_DST" ]]; then
    echo "[action] Translate unique lines via Qwen CLI, then save to: $UNIQUE_DST"
    echo "Suggested command (robust across CLIs):"
    QWEN_BIN_CMD="${QWEN_BIN:-qwen}"
    if [[ -n "${QWEN_MODEL:-}" ]]; then
      MODEL_FLAG=( -m "$QWEN_MODEL" )
    else
      MODEL_FLAG=()
    fi
    echo "     cat \"$QWEN_INPUT\" | $QWEN_BIN_CMD ${MODEL_FLAG[*]} > \"$UNIQUE_DST\""
    echo "Ensure the output has exactly the same number of lines as unique_lines.txt."

    while [[ ! -f "$UNIQUE_DST" ]]; do
      read -r -p "When translation is saved to unique_lines_EN.txt, type 'y' to continue (or 's' to skip): " ans
      if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        if [[ -f "$UNIQUE_DST" ]]; then
          break
        else
          echo "  Still not found: $UNIQUE_DST"
        fi
      elif [[ "$ans" == "s" || "$ans" == "S" ]]; then
        echo "[info] Skipping external LLM step; proceeding to render with current settings."
        SKIP_LLM=1
        break
      fi
    done
  fi

  # If EN exists now and we're not skipping, build per-image JSON arrays and enable external translations
  if [[ -z "$SKIP_LLM" && -f "$UNIQUE_DST" ]]; then
    python "$here/llm_translate_mapping.py" --chapter "$CHAPTER"
    EXTERNAL_TRANS_DIR="$AGG_DIR/llm"
  fi
fi
# Seed dicts on first run, do not overwrite if already present
[[ -f "$DICT_DIR/pre_dict.txt" ]] || cp "$AGG_DIR/template_pre_dict.txt" "$DICT_DIR/pre_dict.txt"
[[ -f "$DICT_DIR/post_dict.txt" ]] || cp "$AGG_DIR/template_post_dict.txt" "$DICT_DIR/post_dict.txt"

if [[ "$EXTRACT_ONLY" == true ]]; then
  echo "[done] Extract + aggregate complete. Edit $DICT_DIR/*.txt then rerun without --extract-only."
  exit 0
fi

echo "[3/3] Translate + render with dictionaries"
RENDER_FLAGS=("--overwrite" "--skip-no-text")
[[ -f "$DICT_DIR/pre_dict.txt" ]] && RENDER_FLAGS+=("--pre-dict" "$DICT_DIR/pre_dict.txt")
[[ -f "$DICT_DIR/post_dict.txt" ]] && RENDER_FLAGS+=("--post-dict" "$DICT_DIR/post_dict.txt")

# Write final images under a chapter-specific subfolder of OUTPUT_DIR
FINAL_OUTPUT_DIR="${OUTPUT_DIR%/}/$CHAPTER"

CONFIG_PATH="$here/mit_config.json" \
CLI_INPUT_DIR="$RUN_INPUT_DIR" \
OUTPUT_DIR="$FINAL_OUTPUT_DIR" \
EXTRA_FLAGS="${RENDER_FLAGS[*]} ${EXTERNAL_TRANS_DIR:+--external-trans-dir $EXTERNAL_TRANS_DIR}" \
bash "$here/mit_run.sh" --use-gpu-limited -v

# Cleanup temporary extract outputs only when a full 3-step run occurred
if [[ "$RENDER_ONLY" != true && "$EXTRACT_ONLY" != true ]]; then
  EXTRACT_OUTPUT_BASE="${EXTRACT_OUTPUT_DIR:-./samples_out_extract}"
  EXTRACT_OUTPUT_DIR="$EXTRACT_OUTPUT_BASE/$CHAPTER"
  if [[ -d "$EXTRACT_OUTPUT_DIR" ]]; then
    echo "[cleanup] Removing temporary extract images at $EXTRACT_OUTPUT_DIR"
    rm -rf "$EXTRACT_OUTPUT_DIR"
  fi
fi

# Always keep final output folder clean (images only)
if [[ -d "$FINAL_OUTPUT_DIR" ]]; then
  echo "[cleanup] Removing text dumps from $FINAL_OUTPUT_DIR (*_translations.txt)"
  find "$FINAL_OUTPUT_DIR" -type f -name "*_translations.txt" -delete 2>/dev/null || true
fi

echo "[done] Results in $FINAL_OUTPUT_DIR. Aggregates in $AGG_DIR. Dictionaries in $DICT_DIR."
