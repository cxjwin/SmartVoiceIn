#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Load local secrets if available
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

PROJECT="VoiceInput.xcodeproj"
SCHEME="VoiceInput"
CONFIGURATION="Release"

TEAM_ID="${SMARTVOICEIN_TEAM_ID:-}"
NOTARY_PROFILE="${SMARTVOICEIN_NOTARY_PROFILE:-smartvoicein-notary}"
APPLE_ID="${SMARTVOICEIN_APPLE_ID:-}"
APP_PASSWORD="${SMARTVOICEIN_APP_PASSWORD:-}"
SIGN_IDENTITY="${SMARTVOICEIN_SIGN_IDENTITY:-Developer ID Application}"

ARCHIVE_PATH="build/SmartVoiceIn.xcarchive"
ZIP_PATH="build/SmartVoiceIn.zip"

SKIP_XCODEGEN=0
SKIP_NOTARIZE=0
SKIP_STAPLE=0
SKIP_VERIFY=0
STORE_CREDENTIALS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh [options]

Options:
  --team-id <TEAM_ID>              Apple Team ID (required)
  --notary-profile <name>          notarytool keychain profile (default: smartvoicein-notary)
  --apple-id <email>               Apple ID for storing notary credentials
  --app-password <password>        App-specific password for storing notary credentials
  --sign-identity <name>           Code sign identity (default: Developer ID Application)
  --store-credentials              Run `notarytool store-credentials` before submit
  --archive-path <path>            Archive output path (default: build/SmartVoiceIn.xcarchive)
  --zip-path <path>                Zip output path (default: build/SmartVoiceIn.zip)
  --skip-xcodegen                  Skip `xcodegen generate`
  --skip-notarize                  Skip notarization submit/wait
  --skip-staple                    Skip stapling notarization ticket
  --skip-verify                    Skip local verification (codesign/spctl)
  -h, --help                       Show help

Environment variables:
  SMARTVOICEIN_TEAM_ID
  SMARTVOICEIN_NOTARY_PROFILE
  SMARTVOICEIN_APPLE_ID
  SMARTVOICEIN_APP_PASSWORD
  SMARTVOICEIN_SIGN_IDENTITY
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="${2:-}"
      shift 2
      ;;
    --app-password)
      APP_PASSWORD="${2:-}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --store-credentials)
      STORE_CREDENTIALS=1
      shift
      ;;
    --archive-path)
      ARCHIVE_PATH="${2:-}"
      shift 2
      ;;
    --zip-path)
      ZIP_PATH="${2:-}"
      shift 2
      ;;
    --skip-xcodegen)
      SKIP_XCODEGEN=1
      shift
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --skip-staple)
      SKIP_STAPLE=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[release] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TEAM_ID" ]]; then
  echo "[release] Missing required option: --team-id <TEAM_ID>" >&2
  exit 1
fi

if [[ "$SKIP_NOTARIZE" -eq 1 && "$SKIP_STAPLE" -eq 0 ]]; then
  echo "[release] --skip-notarize is set, auto-enabling --skip-staple." >&2
  SKIP_STAPLE=1
fi

if [[ "$SKIP_XCODEGEN" -eq 0 ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "[release] xcodegen 未安装，请先安装（brew install xcodegen）" >&2
    exit 1
  fi
fi

for cmd in xcodebuild ditto xcrun codesign spctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[release] Required command not found: $cmd" >&2
    exit 1
  fi
done

if [[ "$SKIP_XCODEGEN" -eq 0 ]]; then
  echo "[release] Generating Xcode project..."
  xcodegen generate >/dev/null
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"
mkdir -p "$(dirname "$ZIP_PATH")"

ARCHIVE_LOG="/tmp/smartvoicein_release_archive.log"
echo "[release] Archiving $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  >"$ARCHIVE_LOG"

APP_PATH="$ARCHIVE_PATH/Products/Applications/SmartVoiceIn.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "[release] Archive succeeded but app not found: $APP_PATH" >&2
  echo "[release] Build log: $ARCHIVE_LOG" >&2
  exit 1
fi

echo "[release] Packaging app -> zip..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  if [[ "$STORE_CREDENTIALS" -eq 1 ]]; then
    if [[ -z "$APPLE_ID" || -z "$APP_PASSWORD" ]]; then
      echo "[release] --store-credentials requires --apple-id and --app-password." >&2
      exit 1
    fi
    echo "[release] Storing notary credentials in keychain profile: $NOTARY_PROFILE"
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \
      --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" \
      --password "$APP_PASSWORD" \
      >/dev/null
  fi

  echo "[release] Submitting zip for notarization..."
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

if [[ "$SKIP_STAPLE" -eq 0 ]]; then
  echo "[release] Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"
fi

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
  echo "[release] Verifying code signature..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  echo "[release] Verifying Gatekeeper assessment..."
  spctl --assess --type execute --verbose "$APP_PATH"
fi

echo "[release] Done."
echo "[release] App path: $APP_PATH"
echo "[release] Zip path: $ZIP_PATH"
echo "[release] Archive log: $ARCHIVE_LOG"
