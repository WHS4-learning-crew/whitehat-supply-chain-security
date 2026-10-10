#!/bin/bash
# ============================================
# run-tier-scan.sh  (poc/asset-risk-tier 브랜치 전용 — main 반영 X)
#
# 자산 등급에 따라 Trivy 차단 임계값만 분기하는 PoC 스크립트
#   - external (외부 노출 자산): HIGH 이상이면 차단
#   - internal (내부 전용 자산): CRITICAL만 차단  ← 현재 main 파이프라인 기준과 같음
#
# 스캔 자체는 두 등급 모두 똑같이 CRITICAL,HIGH로 수행하고,
# "무엇을 차단 사유로 볼지"만 등급에 따라 달라짐.
# 그래서 스캔 시간은 등급과 관계없이 같음 (한계 — 설계 문서 참고)
#
# 기존 run-trivy-scan.sh의 옵션(--ignore-unfixed, .trivyignore, 고유 CVE 집계)을 그대로 따름
#
# 사용법:
#   ./scripts/run-tier-scan.sh <external|internal> [이미지명:태그]
#
# 로컬 예시:
#   docker build -f app/Dockerfile.poc -t whitehat-demo:poc app/
#   ./scripts/run-tier-scan.sh external whitehat-demo:poc   # → FAIL 예상
#   ./scripts/run-tier-scan.sh internal whitehat-demo:poc   # → PASS 예상
# ============================================

set -euo pipefail

TIER="${1:-}"
IMAGE="${2:-whitehat-demo:poc}"

# ---------- 등급 → 차단 기준 ----------
case "$TIER" in
  external) BLOCK_SEVERITIES='["CRITICAL","HIGH"]'; TIER_LABEL="외부 노출 자산" ;;
  internal) BLOCK_SEVERITIES='["CRITICAL"]';        TIER_LABEL="내부 전용 자산" ;;
  *)
    echo "사용법: $0 <external|internal> [이미지명:태그]"
    exit 2
    ;;
esac

SCAN_SEVERITY="CRITICAL,HIGH"     # 스캔 범위는 등급과 무관하게 동일
IGNOREFILE="app/.trivyignore"
OUTPUT_DIR="tier-scan-results/${TIER}"
RESULTS_JSON="${OUTPUT_DIR}/trivy-results.json"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"

for cmd in trivy jq docker; do
  command -v "$cmd" &> /dev/null || { echo "오류: $cmd 가 설치되어 있지 않습니다."; exit 1; }
done

if ! docker image inspect "$IMAGE" &> /dev/null; then
  echo "오류: 로컬에 이미지가 없습니다: $IMAGE"
  echo "먼저 빌드하세요: docker build -f app/Dockerfile.poc -t $IMAGE app/"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# 같은 이미지를 스캔했다는 증거 — 두 등급의 결과에서 이 값이 같아야 함
IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")

IGNORE_OPTION=""
[ -f "$IGNOREFILE" ] && IGNORE_OPTION="--ignorefile $IGNOREFILE"

echo "=== 자산 등급별 Trivy 스캔 (PoC) ==="
echo "자산 등급    : $TIER ($TIER_LABEL)"
echo "차단 기준    : $(echo "$BLOCK_SEVERITIES" | jq -r 'join(", ")')"
echo "대상 이미지  : $IMAGE"
echo "이미지 ID    : $IMAGE_ID"
echo ""

# ---------- 1. 스캔 (등급과 무관하게 동일) ----------
START=$(date +%s)
# shellcheck disable=SC2086
trivy image \
  --quiet \
  --format json \
  --output "$RESULTS_JSON" \
  --severity "$SCAN_SEVERITY" \
  --ignore-unfixed \
  $IGNORE_OPTION \
  "$IMAGE"
SCAN_SECONDS=$(( $(date +%s) - START ))

# ---------- 2. 등급별 판정 (여기만 등급에 따라 달라짐) ----------
# 패치 가능한 고유 CVE만 대상 (main 파이프라인 후처리와 동일 기준)
UNIQUE_CVES=$(jq -c '
  [.Results[]?.Vulnerabilities[]?
    | select(.FixedVersion != null and .FixedVersion != "")
    | {id: .VulnerabilityID, pkg: .PkgName, installed: .InstalledVersion,
       fixed: .FixedVersion, severity: .Severity}
  ] | unique_by(.id)' "$RESULTS_JSON")

BLOCKING=$(jq -c --argjson block "$BLOCK_SEVERITIES" \
  '[.[] | select(.severity as $s | $block | index($s))]' <<< "$UNIQUE_CVES")
REPORT_ONLY=$(jq -c --argjson block "$BLOCK_SEVERITIES" \
  '[.[] | select(.severity as $s | $block | index($s) | not)]' <<< "$UNIQUE_CVES")

BLOCK_COUNT=$(jq 'length' <<< "$BLOCKING")
REPORT_COUNT=$(jq 'length' <<< "$REPORT_ONLY")
if [ "$BLOCK_COUNT" -gt 0 ]; then VERDICT="FAIL"; else VERDICT="PASS"; fi

print_cves() {
  jq -r '.[] | "  \(.severity)\t\(.id)\t\(.pkg) \(.installed) → \(.fixed)"' <<< "$1"
}

echo "=== 차단 사유 (${BLOCK_COUNT}건) ==="
[ "$BLOCK_COUNT" -gt 0 ] && print_cves "$BLOCKING" || echo "  없음"
echo ""
echo "=== 리포트만, 차단 안 함 (${REPORT_COUNT}건) ==="
[ "$REPORT_COUNT" -gt 0 ] && print_cves "$REPORT_ONLY" || echo "  없음"
echo ""
echo "스캔 소요 시간: ${SCAN_SECONDS}초"

# 비교용 요약 파일 (CI의 compare Job이 두 등급 결과를 한 표로 모음)
jq -n \
  --arg tier "$TIER" --arg tier_label "$TIER_LABEL" --arg image "$IMAGE" --arg image_id "$IMAGE_ID" \
  --argjson block_sev "$BLOCK_SEVERITIES" --arg verdict "$VERDICT" \
  --argjson scan_seconds "$SCAN_SECONDS" \
  --argjson blocking "$BLOCKING" --argjson report_only "$REPORT_ONLY" \
  '{tier: $tier, tier_label: $tier_label, image: $image, image_id: $image_id,
    block_severities: $block_sev, verdict: $verdict, scan_seconds: $scan_seconds,
    blocking: $blocking, report_only: $report_only}' > "$SUMMARY_JSON"

# ---------- 3. 최종 판정 ----------
if [ "$VERDICT" = "FAIL" ]; then
  MSG="[$TIER] 차단 기준($(jq -r 'join(", ")' <<< "$BLOCK_SEVERITIES")) 해당 CVE ${BLOCK_COUNT}건 — 배포 차단"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$MSG"; else echo "[FAIL] $MSG"; fi
  exit 1
else
  MSG="[$TIER] 차단 기준 해당 CVE 없음 — 통과 (리포트만 ${REPORT_COUNT}건)"
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$REPORT_COUNT" -gt 0 ]; then echo "::warning::$MSG"; else echo "[PASS] $MSG"; fi
  exit 0
fi
