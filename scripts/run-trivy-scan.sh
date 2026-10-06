#!/bin/bash
# ============================================
# run-trivy-scan.sh
#
#
# GitHub Actions 없이도 동작하도록, actions/cache 등
# GitHub 전용 기능은 제외하고 Trivy 자체 캐싱 + 순수 bash로 구성
#
# 사전 준비:
# - trivy 설치
# - jq 설치
#
# 사용법:
#   ./scripts/run-trivy-scan.sh [이미지명:태그]
#
# 이미지 처리 방식:
#   - 인자로 넘긴 이미지가 로컬에 이미 있으면 → 바로 스캔
#   - 로컬에 없으면 → docker pull을 자동으로 시도한 뒤 스캔
#     (Docker Hub 등 공개 레지스트리에 있는 이미지만 가능.
#      현재 프로젝트의 whitehat-demo:latest처럼 로컬에서 직접
#      build해야 하는 이미지는 미리 docker build 해둘 것)
#
# 예시:
#   ./scripts/run-trivy-scan.sh                     # 기본값(whitehat-demo:latest) 스캔 - 미리 build 필요
#   ./scripts/run-trivy-scan.sh alpine:3.10          # Docker Hub 공개 이미지 - 없으면 자동 pull
#   ./scripts/run-trivy-scan.sh myimage:v1.0         # 임의 이미지 지정 스캔
# ============================================

set -euo pipefail

# ---------- 설정값 ----------
IMAGE="${1:-whitehat-demo:latest}"
SEVERITY="CRITICAL,HIGH"
IGNOREFILE="app/.trivyignore"
OUTPUT_DIR="trivy-scan-results"
RESULTS_JSON="${OUTPUT_DIR}/trivy-results.json"
CRITICAL_TSV="${OUTPUT_DIR}/unique-cves-critical.tsv"
HIGH_TSV="${OUTPUT_DIR}/unique-cves-high.tsv"

# ---------- 사전 점검 ----------
echo "=== 사전 점검 ==="

if ! command -v trivy &> /dev/null; then
  echo "오류: trivy가 설치되어 있지 않습니다."
  echo "설치: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "오류: jq가 설치되어 있지 않습니다."
  echo "설치(Ubuntu/WSL): sudo apt install -y jq"
  exit 1
fi

if ! docker image inspect "$IMAGE" &> /dev/null; then
  echo "로컬에서 이미지를 찾지 못했습니다: $IMAGE"
  echo "docker pull을 시도합니다..."
  if docker pull "$IMAGE"; then
    echo "pull 성공: $IMAGE"
  else
    echo ""
    echo "오류: pull도 실패했습니다."
    echo "  - 이미지 이름/태그가 정확한지 확인하세요"
    echo "  - 로컬 전용 이미지(whitehat-demo:latest 등)라면"
    echo "    docker build로 먼저 이미지를 만들어두세요"
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR"

echo "대상 이미지: $IMAGE"
echo "Severity: $SEVERITY"
if [ -f "$IGNOREFILE" ]; then
  echo "Waiver 파일 적용: $IGNOREFILE"
  IGNORE_OPTION="--ignorefile $IGNOREFILE"
else
  echo "Waiver 파일 없음 (건너뜀): $IGNOREFILE"
  IGNORE_OPTION=""
fi
echo ""

# ---------- 1. Trivy 스캔 ----------
echo "=== 1. Trivy 스캔 실행 ==="

# shellcheck disable=SC2086
trivy image \
  --format json \
  --output "$RESULTS_JSON" \
  --severity "$SEVERITY" \
  --ignore-unfixed \
  $IGNORE_OPTION \
  "$IMAGE"

echo "스캔 완료: $RESULTS_JSON"
echo ""

# ---------- 2. 후처리  ----------
echo "=== 2. CRITICAL (fail 대상) ==="
jq -r '
  [.Results[]?.Vulnerabilities[]?
    | select(.Severity == "CRITICAL" and .FixedVersion != null and .FixedVersion != "")
  ]
  | unique_by(.VulnerabilityID)
  | .[]
  | "\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion)\t\(.Severity)"
' "$RESULTS_JSON" | tee "$CRITICAL_TSV"

echo ""
echo "=== 3. HIGH (리포트만, fail X) ==="
jq -r '
  [.Results[]?.Vulnerabilities[]?
    | select(.Severity == "HIGH" and .FixedVersion != null and .FixedVersion != "")
  ]
  | unique_by(.VulnerabilityID)
  | .[]
  | "\(.VulnerabilityID)\t\(.PkgName)\t\(.InstalledVersion)\t\(.FixedVersion)\t\(.Severity)"
' "$RESULTS_JSON" | tee "$HIGH_TSV"

CRITICAL_COUNT=$(wc -l < "$CRITICAL_TSV" | tr -d ' ')
HIGH_COUNT=$(wc -l < "$HIGH_TSV" | tr -d ' ')

echo ""
echo "=== 결과 요약 ==="
echo "CRITICAL 고유 CVE: $CRITICAL_COUNT 건 (fail 대상)"
echo "HIGH 고유 CVE: $HIGH_COUNT 건 (리포트만, warning)"
echo ""
echo "결과 파일 위치: $OUTPUT_DIR/"

# ---------- 3. 최종 판정 (exit code 로직) ----------
if [ "$HIGH_COUNT" -gt 0 ]; then
  echo "[WARNING] HIGH 등급 고유 CVE ${HIGH_COUNT}건 발견 — 참고용 기록"
fi

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  echo "[FAIL] CRITICAL 등급 + 패치 가능한 고유 CVE ${CRITICAL_COUNT}건 발견"
  exit 1
else
  echo "[PASS] 패치 가능한 CRITICAL CVE 없음 — 통과"
  exit 0
fi
