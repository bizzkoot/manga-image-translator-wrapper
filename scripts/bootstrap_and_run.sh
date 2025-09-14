#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

echo "[1/7] Select a supported Python (3.10/3.11)"
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

echo "[2/7] Ensure Python venv (${ver})"
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

echo "[3/7] Fetch manga-image-translator if missing"
MIT_DIR="$root/third_party/manga-image-translator"
if [[ ! -d "$MIT_DIR" ]]; then
  mkdir -p "$root/third_party"
  git clone https://github.com/zyddnys/manga-image-translator.git "$MIT_DIR"
fi

# Optionally pin upstream to a specific commit/tag for stability
if [[ -n "${MIT_COMMIT:-}" ]]; then
  echo "[3b/7] Pinning manga-image-translator to ${MIT_COMMIT}"
  git -C "$MIT_DIR" fetch --all --tags || true
  git -C "$MIT_DIR" checkout --quiet "$MIT_COMMIT" || {
    echo "[warn] Failed to checkout ${MIT_COMMIT}. Continuing on current HEAD." >&2
  }
fi

# Optionally apply small, non-invasive patches for stable extract dumps
if [[ "${APPLY_MIT_PATCH:-1}" == "1" ]]; then
  echo "[3c/7] Patching upstream for reliable per-image text dumps"
  PYFILE="$MIT_DIR/manga_translator/mode/local.py"
  if [[ -f "$PYFILE" ]]; then
    python - "$PYFILE" <<'PY'
import io, os, sys, re
p = sys.argv[1]
src = io.open(p, 'r', encoding='utf-8').read()
orig = src
# 1) Honor --save-text-file by reading save_text_file instead of text_output_file
src = src.replace('text_output_file = self.text_output_file', 'text_output_file = self.save_text_file or ""')
# 2) Use ctx.text_regions gate instead of self.text_regions if present
src = src.replace('if self.text_regions:', 'if ctx.text_regions:')
if src != orig:
    bak = p + '.bak'
    with io.open(bak, 'w', encoding='utf-8') as f:
        f.write(orig)
    with io.open(p, 'w', encoding='utf-8') as f:
        f.write(src)
    print('[patch] Updated', p)
else:
    print('[patch] No changes needed for', p)
PY
  else
    echo "[patch] Skipped: $PYFILE not found"
  fi
fi

# Apply custom patches
echo "[3d/7] Applying custom patches"
sed -i.bak "s/'kn': 'kor_Hang'/'ko': 'kor_Hang'/" "$MIT_DIR/manga_translator/translators/nllb.py"
sed -i.bak "/g_parser.add_argument('--context-size', default=0, type=int, help='Pages of context are needed for translating the current page')/a g_parser.add_argument('--external-trans-dir', default=None, type=str, help='Directory containing per-image translations as JSON arrays named <basename>_translations.json')" "$MIT_DIR/manga_translator/args.py"
sed -i.bak "/self.load_text = params.get('load_text', False)/a \
        # External per-image translations directory (JSON arrays)\
        self.external_trans_dir = params.get('external_trans_dir', None)\
        self.current_input_basename = None" "$MIT_DIR/manga_translator/manga_translator.py"
sed -i.bak "/if config.translator.translator == Translator.none:/a \
        # External per-image translations: if provided, load and apply, skipping MT\
        if getattr(self, 'external_trans_dir', None):\
            try:\
                if self.current_input_basename:\
                    p = os.path.join(self.external_trans_dir, f\"{self.current_input_basename}_translations.json\")\
                    if os.path.exists(p):\
                        with open(p, 'r', encoding='utf-8') as f:\
                            translated_sentences = json.load(f)\
                        for region, translation in zip(ctx.text_regions, translated_sentences):\
                            region.translation = translation\
                            region.target_lang = config.translator.target_lang\
                            region._alignment = config.render.alignment\
                            region._direction = config.render.direction\
                        return ctx.text_regions
            except Exception as e:\
                logger.warning(f"Failed to load external translations: {e}")" "$MIT_DIR/manga_translator/manga_translator.py"
sed -i.bak "/# dispatch(chain, queries, translator_config=None, use_mtpe=False, args=None, device='cpu')/a \
            translated_sentences = await dispatch_translation(\
                config.translator.translator_gen,\\
                queries,\\
                use_mtpe=self.use_mtpe,\\
                args=ctx,\\
                device='cpu' if self._gpu_limited_memory else self.device,\\
            )" "$MIT_DIR/manga_translator/mode/local.py"
sed -i.bak "/# 直接翻译图片，不再需要传递文件名/a \
            try:\
                # Provide basename to core for external translation lookup\
                self.current_input_basename = os.path.splitext(os.path.basename(path))[0]\
            except Exception:\
                self.current_input_basename = None" "$MIT_DIR/manga_translator/mode/local.py"

echo "[4/7] Install project dependencies"

pip install -r "$MIT_DIR/requirements.txt"

echo "[5/7] Install CTranslate2 + tooling"
pip install 'ctranslate2>=4.6' transformers sentencepiece huggingface_hub

echo "[6/7] Download small NLLB model (CT2)"
bash "$here/get_nllb_small.sh"

echo "[7/7] Run a small batch"
mkdir -p samples_in samples_out
MIT_ROOT="$MIT_DIR" bash "$here/mit_run.sh"
