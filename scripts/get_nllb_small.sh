#!/usr/bin/env bash
set -euo pipefail

mkdir -p ./models

pip install -q 'ctranslate2>=4.6' transformers sentencepiece huggingface_hub

ct2-transformers-converter \
  --model facebook/nllb-200-distilled-600M \
  --output_dir ./models/nllb-200-600M-ct2 \
  --copy_files tokenizer.json tokenizer_config.json \
  --force

echo "Model ready at ./models/nllb-200-600M-ct2"

