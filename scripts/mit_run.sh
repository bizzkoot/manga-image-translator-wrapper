#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

if [[ -f "$here/mit_mac.env" ]]; then
  # Preserve user-provided EXTRA_FLAGS if set in environment
  USER_EXTRA_FLAGS="${EXTRA_FLAGS:-}"
  USER_INPUT_DIR="${INPUT_DIR:-}"
  USER_OUTPUT_DIR="${OUTPUT_DIR:-}"
  USER_FONT_PATH="${FONT_PATH:-}"
  USER_CONFIG_PATH="${CONFIG_PATH:-}"
  # shellcheck disable=SC1091
  source "$here/mit_mac.env"
  # Restore user-provided EXTRA_FLAGS to override env defaults
  if [[ -n "${USER_EXTRA_FLAGS}" ]]; then
    EXTRA_FLAGS="${USER_EXTRA_FLAGS}"
  fi
  # Allow caller overrides for input/output/font/config
  if [[ -n "${USER_INPUT_DIR}" ]]; then INPUT_DIR="${USER_INPUT_DIR}"; fi
  if [[ -n "${USER_OUTPUT_DIR}" ]]; then OUTPUT_DIR="${USER_OUTPUT_DIR}"; fi
  if [[ -n "${USER_FONT_PATH}" ]]; then FONT_PATH="${USER_FONT_PATH}"; fi
  if [[ -n "${USER_CONFIG_PATH}" ]]; then CONFIG_PATH="${USER_CONFIG_PATH}"; fi
else
  echo "Missing $here/mit_mac.env" >&2
  exit 1
fi

# Locate manga-image-translator entry
MIT_ROOT="${MIT_ROOT:-$root}"
if [[ ! -f "$MIT_ROOT/MangaStudioMain.py" ]]; then
  # Fallback to third_party location if present
  if [[ -f "$root/third_party/manga-image-translator/MangaStudioMain.py" ]]; then
    MIT_ROOT="$root/third_party/manga-image-translator"
  else
    echo "Could not find MangaStudioMain.py in $MIT_ROOT or third_party." >&2
    echo "Set MIT_ROOT to your manga-image-translator path and retry." >&2
    exit 1
  fi
fi

# Choose Python interpreter
PY_BIN="${PYTHON_BIN:-}"
if [[ -z "${PY_BIN}" ]]; then
  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
    PY_BIN="${VIRTUAL_ENV}/bin/python"
  elif [[ -x "${root}/.venv/bin/python" ]]; then
    PY_BIN="${root}/.venv/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    PY_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PY_BIN="python"
  else
    echo "Could not find a Python interpreter. Activate your venv or set PYTHON_BIN=python3.11" >&2
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR"
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
# Avoid HF tokenizers fork warning and potential stall
export TOKENIZERS_PARALLELISM="${TOKENIZERS_PARALLELISM:-false}"
# Ensure Python can find the cloned package
export PYTHONPATH="$MIT_ROOT${PYTHONPATH:+:$PYTHONPATH}"

# Build a minimal JSON config for the CLI
CONFIG_PATH="${CONFIG_PATH:-scripts/mit_config.json}"
if [[ ! -f "$CONFIG_PATH" ]]; then
  cat > "$CONFIG_PATH" <<'JSON'
{
  "translator": {
    "translator": "nllb",
    "target_lang": "ENG"
  },
  "detector": {
    "detector": "ctd",
    "detection_size": 1536
  },
  "inpainter": {
    "inpainting_size": 1536,
    "inpainting_precision": "bf16"
  }
}
JSON
fi

# Allow a caller-provided CLI_INPUT_DIR to override the env INPUT_DIR cleanly
EFFECTIVE_INPUT_DIR="${CLI_INPUT_DIR:-$INPUT_DIR}"

set -x
"$PY_BIN" -m manga_translator \
  local \
  -i "$EFFECTIVE_INPUT_DIR" \
  -o "$OUTPUT_DIR" \
  --config-file "$CONFIG_PATH" \
  ${FONT_PATH:+--font-path "$FONT_PATH"} \
  $EXTRA_FLAGS \
  "$@"
set +x

# Open output in Finder on macOS (optional)
open "$OUTPUT_DIR" 2>/dev/null || true
