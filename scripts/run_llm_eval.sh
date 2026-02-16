#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[run_llm_eval] xcodegen 未安装，请先安装（brew install xcodegen）" >&2
  exit 1
fi

echo "[run_llm_eval] Generating Xcode project..."
xcodegen generate >/dev/null

echo "[run_llm_eval] Building LLMEvalCLI (Debug)..."
xcodebuild -project "VoiceInput.xcodeproj" -scheme "LLMEvalCLI" -configuration Debug build >/tmp/llm_eval_build.log

BUILT_PRODUCTS_DIR="$(xcodebuild -project "VoiceInput.xcodeproj" -scheme "LLMEvalCLI" -configuration Debug -showBuildSettings 2>/dev/null | awk -F ' = ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')"
BIN_PATH="${BUILT_PRODUCTS_DIR}/LLMEvalCLI"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "[run_llm_eval] 未找到可执行文件: $BIN_PATH" >&2
  echo "[run_llm_eval] 构建日志: /tmp/llm_eval_build.log" >&2
  exit 1
fi

echo "[run_llm_eval] Running: $BIN_PATH $*"
"$BIN_PATH" "$@"
