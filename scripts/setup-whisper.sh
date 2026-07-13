#!/bin/zsh
set -euo pipefail

MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
MODEL_SHA1="e050f7970618a659205450ad97eb95a18d69c9ee"
MODEL_DIR="$HOME/Library/Application Support/Desklog/models"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrewが必要です: https://brew.sh/" >&2
    exit 1
fi

if ! brew list whisper-cpp >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew install whisper-cpp
fi

mkdir -p "$MODEL_DIR"
chmod 700 "$MODEL_DIR"
if [[ ! -f "$MODEL_PATH" ]] || [[ "$(shasum "$MODEL_PATH" | awk '{print $1}')" != "$MODEL_SHA1" ]]; then
    curl -L --fail --continue-at - --output "$MODEL_PATH" "$MODEL_URL"
fi

ACTUAL_SHA1="$(shasum "$MODEL_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA1" != "$MODEL_SHA1" ]]; then
    echo "モデルのチェックサムが一致しません: $MODEL_PATH" >&2
    exit 1
fi
chmod 600 "$MODEL_PATH"

echo "Whisper ready"
echo "Executable: $(command -v whisper-cli)"
echo "Model: $MODEL_PATH"
