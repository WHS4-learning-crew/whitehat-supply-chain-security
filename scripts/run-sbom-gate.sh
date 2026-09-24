#!/usr/bin/env bash
# Usage:
#   ./scripts/run-sbom-gate.sh [baseline-ref] [output-directory]
# Example:
#   ./scripts/run-sbom-gate.sh HEAD^ artifacts/sbom

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_REF="${1:-HEAD^}"
OUTPUT_DIR="${2:-$ROOT_DIR/artifacts/sbom}"
APP_DIR="$ROOT_DIR/app"
BASELINE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$BASELINE_DIR"
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 2
  fi
}

require_command git
require_command syft
require_command grype
require_command python3

if ! git -C "$ROOT_DIR" rev-parse --verify -q "${BASELINE_REF}^{commit}" >/dev/null; then
  echo "Baseline ref is not a commit: $BASELINE_REF" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
git -C "$ROOT_DIR" archive "$BASELINE_REF:app" | tar -x -C "$BASELINE_DIR"

echo "[1/4] Generating current SBOM"
syft "dir:$APP_DIR" -o cyclonedx-json > "$OUTPUT_DIR/sbom-current.json"

echo "[2/4] Generating baseline SBOM from $BASELINE_REF"
syft "dir:$BASELINE_DIR" -o cyclonedx-json > "$OUTPUT_DIR/sbom-baseline.json"

echo "[3/4] Comparing and scoring new packages"
python3 "$ROOT_DIR/scripts/sbom_gate.py" \
  --baseline "$OUTPUT_DIR/sbom-baseline.json" \
  --current "$OUTPUT_DIR/sbom-current.json" \
  --baseline-lock "$BASELINE_DIR/package-lock.json" \
  --current-lock "$APP_DIR/package-lock.json" \
  --threshold 60 \
  --report "$OUTPUT_DIR/sbom-risk-report.json"

echo "[4/4] Scanning current SBOM with Grype"
grype "sbom:$OUTPUT_DIR/sbom-current.json" -o json > "$OUTPUT_DIR/grype-report.json"

echo "PASS: SBOM gate completed. Evidence saved to: $OUTPUT_DIR"