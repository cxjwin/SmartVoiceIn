#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="VoiceInput.xcodeproj"
SCHEME="VoiceInput"
CONFIGURATION="Debug"
SKIP_XCODEGEN=0
RUN_AFTER_BUILD=0

usage() {
  cat <<'EOF'
Usage: ./scripts/build_app.sh [options]

Options:
  --configuration <Debug|Release>   Build configuration (default: Debug)
  --skip-xcodegen                   Skip `xcodegen generate`
  --run                             Run the built app executable after build
  -h, --help                        Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --skip-xcodegen)
      SKIP_XCODEGEN=1
      shift
      ;;
    --run)
      RUN_AFTER_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[build_app] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$SKIP_XCODEGEN" -eq 0 ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[build_app] xcodegen 未安装，请先安装（brew install xcodegen）" >&2
    exit 1
  fi
  echo "[build_app] Generating Xcode project..."
  xcodegen generate >/dev/null
fi

echo "[build_app] Building scheme=$SCHEME configuration=$CONFIGURATION ..."
BUILD_LOG="/tmp/smartvoicein_build.log"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$BUILD_LOG"

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
BUILT_PRODUCTS_DIR="$(awk -F ' = ' '$1 ~ /BUILT_PRODUCTS_DIR$/ {print $2; exit}' <<<"$BUILD_SETTINGS")"
FULL_PRODUCT_NAME="$(awk -F ' = ' '$1 ~ /FULL_PRODUCT_NAME$/ {print $2; exit}' <<<"$BUILD_SETTINGS")"
EXECUTABLE_PATH="$(awk -F ' = ' '$1 ~ /EXECUTABLE_PATH$/ {print $2; exit}' <<<"$BUILD_SETTINGS")"

APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
BIN_PATH="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"

if [[ ! -d "$APP_PATH" || ! -x "$BIN_PATH" ]]; then
  echo "[build_app] Build finished but app/executable not found." >&2
  echo "[build_app] Expected app: $APP_PATH" >&2
  echo "[build_app] Expected bin: $BIN_PATH" >&2
  echo "[build_app] Build log: $BUILD_LOG" >&2
  exit 1
fi

echo "[build_app] Build succeeded."
echo "[build_app] App path: $APP_PATH"
echo "[build_app] Executable path: $BIN_PATH"
echo "[build_app] Build log: $BUILD_LOG"

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
  echo "[build_app] Running executable..."
  "$BIN_PATH"
fi
