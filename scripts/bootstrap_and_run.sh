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

# Optionally apply small, non-invasive patches for stable extract dumps
if [[ "${APPLY_MIT_PATCH:-1}" == "1" ]]; then
  echo "[3c/8] Patching upstream for reliable per-image text dumps"
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

## Note: Custom patches moved to the end for safety

echo "[4/8] Install project dependencies"

pip install -r "$MIT_DIR/requirements.txt"

echo "[5/8] Install CTranslate2 + tooling"
pip install 'ctranslate2>=4.6' transformers sentencepiece huggingface_hub

echo "[6/8] Download small NLLB model (CT2)"
bash "$here/get_nllb_small.sh"

echo "[7/8] Run a small batch"
mkdir -p samples_in samples_out
MIT_ROOT="$MIT_DIR" bash "$here/mit_run.sh"

# Apply custom patches at the end to ensure upstream files exist and deps installed
echo "[8/8] Applying custom patches"
python - <<'PY'
import io, os, re, json, sys

# When executing via stdin (__file__ may be '<stdin>' or undefined),
# rely on current working directory which the script has already set to repo root.
root = os.path.abspath(os.getcwd())
mit_dir = os.path.join(root, 'third_party', 'manga-image-translator')

def load(p):
    try:
        with io.open(p, 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return None

def save(p, s):
    with io.open(p + '.bak', 'w', encoding='utf-8') as f:
        f.write(load(p) or '')
    with io.open(p, 'w', encoding='utf-8') as f:
        f.write(s)

def insert_after_line(p, needle, block, presence_hint=None):
    s = load(p)
    if s is None:
        print(f"[patch] Skipped: {p} not found")
        return
    if presence_hint and presence_hint in s:
        print(f"[patch] Already present in {p}; skip insert")
        return
    lines = s.splitlines(True)
    idx = None
    for i, line in enumerate(lines):
        if needle in line:
            idx = i
            break
    if idx is None:
        print(f"[patch] Needle not found in {p}; skip insert")
        return
    insert = block
    if not insert.endswith('\n'):
        insert += '\n'
    lines[idx+1:idx+1] = [insert]
    save(p, ''.join(lines))
    print(f"[patch] Inserted block into {p}")

# 1) translators/nllb.py: ensure 'ko' key (if someone had 'kn')
nllb_py = os.path.join(mit_dir, 'manga_translator', 'translators', 'nllb.py')
src = load(nllb_py)
if src is not None:
    s2 = src.replace("'kn': 'kor_Hang'", "'ko': 'kor_Hang'")
    if s2 != src:
        save(nllb_py, s2)
        print(f"[patch] Updated: {nllb_py} (ko key fix)")
    else:
        print(f"[patch] No changes needed for {nllb_py}")
else:
    print(f"[patch] Skipped: {nllb_py} not found")

# 2) args.py: add --external-trans-dir after --context-size
args_py = os.path.join(mit_dir, 'manga_translator', 'args.py')
insert_after_line(
    args_py,
    "g_parser.add_argument('--context-size',",
    "        g_parser.add_argument('--external-trans-dir', default=None, type=str, help='Directory containing per-image translations as JSON arrays named <basename>_translations.json')",
    presence_hint="--external-trans-dir",
)

# 3) manga_translator.py: add fields after self.load_text ...
core_py = os.path.join(mit_dir, 'manga_translator', 'manga_translator.py')
insert_after_line(
    core_py,
    "self.load_text = params.get('load_text', False)",
    "        # External per-image translations directory (JSON arrays)\n        self.external_trans_dir = params.get('external_trans_dir', None)\n        self.current_input_basename = None",
    presence_hint='external_trans_dir',
)

# 4) manga_translator.py: external translations fast-path before any translator
block4 = (
    "        # First: if external per-image translations are provided, prefer them and skip MT\n"
    "        if getattr(self, 'external_trans_dir', None):\n"
    "            try:\n"
    "                if self.current_input_basename:\n"
    "                    p = os.path.join(self.external_trans_dir, f\"{self.current_input_basename}_translations.json\")\n"
    "                    if os.path.exists(p):\n"
    "                        with open(p, 'r', encoding='utf-8') as f:\n"
    "                            translated_sentences = json.load(f)\n"
    "                        for region, translation in zip(ctx.text_regions, translated_sentences):\n"
    "                            region.translation = translation\n"
    "                            region.target_lang = config.translator.target_lang\n"
    "                            region._alignment = config.render.alignment\n"
    "                            region._direction = config.render.direction\n"
    "                        return ctx.text_regions\n"
    "            except Exception as e:\n"
    "                logger.warning(f\"Failed to load external translations: {e}\")\n"
)
insert_after_line(
    core_py,
    "if not ctx.text_regions:",
    block4,
    presence_hint='external translations: if provided',
)

# 5) mode/local.py: ensure dispatch_translation call block exists (after the comment marker)
local_py = os.path.join(mit_dir, 'manga_translator', 'mode', 'local.py')
block5 = (
    "            translated_sentences = await dispatch_translation(\n"
    "                config.translator.translator_gen,\n"
    "                queries,\n"
    "                use_mtpe=self.use_mtpe,\n"
    "                args=ctx,\n"
    "                device='cpu' if self._gpu_limited_memory else self.device,\n"
    "            )\n"
)
insert_after_line(
    local_py,
    "# dispatch(chain, queries, translator_config=None, use_mtpe=False, args=None, device='cpu')",
    block5,
    presence_hint='dispatch_translation(\n',
)

# 6) mode/local.py: set current_input_basename after the Chinese comment marker
block6 = (
    "            try:\n"
    "                # Provide basename to core for external translation lookup\n"
    "                self.current_input_basename = os.path.splitext(os.path.basename(path))[0]\n"
    "            except Exception:\n"
    "                self.current_input_basename = None\n"
)
insert_after_line(
    local_py,
    "# \u76f4\u63a5\u7ffb\u8bd1\u56fe\u7247\uff0c\u4e0d\u518d\u9700\u8981\u4f20\u9012\u6587\u4ef6\u540d",
    block6,
    presence_hint='current_input_basename',
)

# 7) mode/local.py: fix dispatch_translation call for .txt files
local_py = os.path.join(mit_dir, 'manga_translator', 'mode', 'local.py')
src = load(local_py)
if src is not None:
    old_call = "await dispatch_translation(config.translator.translator_gen, queries, self.use_mtpe, ctx, "
    new_call = "await dispatch_translation(config.translator.translator_gen, queries, translator_config=config.translator, use_mtpe=self.use_mtpe, args=ctx, "
    if old_call in src:
        s2 = src.replace(old_call, new_call)
        save(local_py, s2)
        print(f"[patch] Updated: {local_py} (fixed dispatch_translation call for .txt files)")
    else:
        print(f"[patch] No changes needed for {local_py} (dispatch_translation call for .txt files)")
else:
    print(f"[patch] Skipped: {local_py} not found")

print('[patch] Custom patching completed')
PY

