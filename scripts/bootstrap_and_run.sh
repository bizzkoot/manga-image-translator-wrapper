#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

echo "[1/8] Select a supported Python (3.10/3.11)"
PY_BIN="${PYTHON_BIN:-}"
if [[ -z "${PY_BIN}" ]]; then
  for c in python3.11 python3.10 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
  done
fi
if [[ -z "${PY_BIN}" ]]; then
  echo "No Python interpreter found. Install Python 3.11 (brew install python@3.11) and rerun with PYTHON_BIN=python3.11" >&2
  exit 1
fi

ver="$($PY_BIN -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
major="${ver%%.*}"
minor="${ver##*.}"
if (( major > 3 || (major == 3 && minor >= 12) )); then
  echo "Detected Python ${ver}. Some deps (pydensecrf, pydantic-core) lack 3.12/3.13 wheels. Please use Python 3.10 or 3.11." >&2
  echo "Tip: brew install python@3.11; then rerun with PYTHON_BIN=python3.11 bash scripts/bootstrap_and_run.sh" >&2
  exit 1
fi

echo "[2/8] Ensure Python venv (${ver})"
need_recreate=false
if [[ -d .venv ]]; then
  current_ver="$(. .venv/bin/activate >/dev/null 2>&1; python -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)"
  deactivate >/dev/null 2>&1 || true
  if [[ -z "$current_ver" ]]; then
    need_recreate=true
  else
    cmaj="${current_ver%%.*}"; cmin="${current_ver##*.}"
    if (( cmaj != 3 || cmin >= 12 )); then
      echo "Existing .venv uses Python ${current_ver}; recreating with ${ver}."
      need_recreate=true
    fi
  fi
fi

if $need_recreate; then
  rm -rf .venv
fi

if [[ ! -d .venv ]]; then
  "$PY_BIN" -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -U pip wheel

echo "[3/8] Fetch manga-image-translator if missing"
MIT_DIR="$root/third_party/manga-image-translator"
if [[ ! -d "$MIT_DIR" ]]; then
  mkdir -p "$root/third_party"
  git clone https://github.com/zyddnys/manga-image-translator.git "$MIT_DIR"
fi

# Optionally pin upstream to a specific commit/tag for stability
if [[ -n "${MIT_COMMIT:-}" ]]; then
  echo "[3b/8] Pinning manga-image-translator to ${MIT_COMMIT}"
  git -C "$MIT_DIR" fetch --all --tags || true
  git -C "$MIT_DIR" checkout --quiet "$MIT_COMMIT" || {
    echo "[warn] Failed to checkout ${MIT_COMMIT}. Continuing on current HEAD." >&2
  }
fi

## Note: Custom golden file install moved to the end for safety

echo "[4/8] Install project dependencies"

pip install -r "$MIT_DIR/requirements.txt"

echo "[5/8] Install CTranslate2 + tooling"
pip install 'ctranslate2>=4.6' transformers sentencepiece huggingface_hub

echo "[6/8] Download small NLLB model (CT2)"
bash "$here/get_nllb_small.sh"

echo "[7/8] Run a small batch"
mkdir -p samples_in samples_out
MIT_ROOT="$MIT_DIR" bash "$here/mit_run.sh"

# Install custom golden files at the end to ensure upstream files exist and deps installed
echo "[8/8] Installing custom golden files"

MIT_DIR="$root/third_party/manga-image-translator"
GOLD_DIR="$here/patched_files"

copy_with_backup() {
  src="$1"; dst="$2"
  if [[ ! -f "$src" ]]; then
    echo "[gold] Missing source: $src" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" && ! -f "$dst.orig" ]]; then
    cp -f "$dst" "$dst.orig"
  fi
  cp -f "$src" "$dst"
  echo "[gold] Installed $(basename "$src") -> ${dst#${root}/}"
}

copy_with_backup "$GOLD_DIR/args.py"             "$MIT_DIR/manga_translator/args.py"
copy_with_backup "$GOLD_DIR/manga_translator.py" "$MIT_DIR/manga_translator/manga_translator.py"
copy_with_backup "$GOLD_DIR/local.py"            "$MIT_DIR/manga_translator/mode/local.py"
copy_with_backup "$GOLD_DIR/nllb.py"             "$MIT_DIR/manga_translator/translators/nllb.py"

echo "[gold] Installation completed"
