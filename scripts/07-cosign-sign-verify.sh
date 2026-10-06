#!/usr/bin/env bash
#
# 07-cosign-sign-verify.sh
#
# 목적: ECR에 올라간 이미지를 대상으로
#   1) Cosign Keyless 서명 (선택, --sign)
#   2) 서명 검증 (identity/issuer 대조)
#   3) Rekor 투명성 로그 조회 (검증 결과에 들어 있는 logIndex 사용)
# 를 한 번에 재현 가능하게 수행한다.
#
# 사용법:
#   ./07-cosign-sign-verify.sh <image-ref> [--sign] [--branch <브랜치[,브랜치...]>]
#
# 예시:
#   # main 기준 검증 (기본값)
#   ./07-cosign-sign-verify.sh 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/whs4-demo-app:<태그>
#
#   # feat/ci-pipeline 기준 검증
#   ./07-cosign-sign-verify.sh <image-ref> --branch feat/ci-pipeline
#
#   # Kyverno 정책처럼 "둘 중 하나면 통과" (쉼표로 구분)
#   ./07-cosign-sign-verify.sh <image-ref> --branch main,feat/ci-pipeline
#
# 종료 코드 (기록표용):
#   0 = 서명 검증 통과
#   2 = 거부: 서명 자체가 없음            (cosign exit 10, 예: B-1 미서명 이미지)
#   3 = 거부: 서명은 있으나 identity 불일치 (cosign exit 12, 예: PR/다른 브랜치 서명)
#   1 = 그 외 오류 (도구 없음, 로그인/네트워크 실패, 이미지 참조 오류 등)
#
# 기본 동작은 verify + Rekor 조회만 수행한다. CI 밖에서 --sign을 하면 새 서명
# 이벤트가 생겨 팀 기록과 어긋날 수 있으므로 명시적으로 옵션을 붙일 때만 서명한다.
#
# 주의: --sign을 로컬에서 실행하면 브라우저 OIDC 로그인이 뜨고 서명자 identity가
# "개인 계정"이 된다. 워크플로 기준 identity로는 검증이 통과하지 않는다(exit 3).
# 이는 스크립트 오류가 아니라 keyless 서명의 정상 동작이다.

set -uo pipefail
# 주: 검증 실패를 "크래시"가 아니라 "관측된 결과"로 다루기 위해 set -e는 쓰지 않는다.

# ── 설정값 ─────────────────────────────────────────────────
AWS_REGION="ap-northeast-2"
REPO_PATH="WHS4-learning-crew/whitehat-supply-chain-security/.github/workflows/ci-pipeline.yml"
CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"
DEFAULT_BRANCH="main"

# ── 인자 처리 ──────────────────────────────────────────────
IMAGE="${1:?사용법: $0 <image-ref> [--sign] [--branch <브랜치[,브랜치...]>]}"
shift

DO_SIGN=""
BRANCH_ARG="$DEFAULT_BRANCH"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)
      DO_SIGN="--sign"
      shift
      ;;
    --branch)
      BRANCH_ARG="${2:?--branch 옵션에는 브랜치명이 필요합니다}"
      shift 2
      ;;
    *)
      echo "❌ 알 수 없는 옵션: $1" >&2
      exit 1
      ;;
  esac
done

REGISTRY="$(echo "$IMAGE" | cut -d'/' -f1)"
IFS=',' read -r -a BRANCHES <<<"$BRANCH_ARG"

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

echo "ℹ️  검증 기준 identity (둘 이상이면 하나만 맞아도 통과):"
for b in "${BRANCHES[@]}"; do
  echo "     - https://github.com/${REPO_PATH}@refs/heads/${b}"
done

# ── 사전 도구 확인 ─────────────────────────────────────────
for cmd in cosign crane aws rekor-cli jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' 명령을 찾을 수 없습니다. PATH 또는 설치 상태를 확인하세요." >&2
    exit 1
  fi
done

# ── 1. ECR 인증 ────────────────────────────────────────────
echo "▶ 1. ECR 로그인 ($REGISTRY)"
if ! aws ecr get-login-password --region "$AWS_REGION" \
  | crane auth login "$REGISTRY" --username AWS --password-stdin; then
  echo "❌ ECR 로그인 실패 — AWS 자격 증명/리전을 확인하세요." >&2
  exit 1
fi

# ── 2. (선택) Cosign 서명 ──────────────────────────────────
if [[ "$DO_SIGN" == "--sign" ]]; then
  echo "▶ 2. Keyless 서명 수행"
  echo "⚠️  로컬 서명은 identity가 개인 계정으로 기록되어 아래 3번 검증은 exit 3(identity 불일치)이 예상됩니다."
  COSIGN_EXPERIMENTAL=1 cosign sign --yes "$IMAGE"
else
  echo "▶ 2. 서명 단계 건너뜀 (재현하려면 --sign 옵션 추가)"
fi

# ── 3. 서명 검증 ───────────────────────────────────────────
# stdout(JSON)과 stderr(안내/에러)를 분리해서 받는다.
echo "▶ 3. 서명 검증"
VERIFY_STATUS=1
VERIFY_JSON=""
MATCHED_IDENTITY=""

for b in "${BRANCHES[@]}"; do
  IDENTITY="https://github.com/${REPO_PATH}@refs/heads/${b}"
  OUT="$(cosign verify \
    --certificate-identity="$IDENTITY" \
    --certificate-oidc-issuer="$CERT_OIDC_ISSUER" \
    "$IMAGE" 2>"$ERR_FILE")"
  VERIFY_STATUS=$?
  if [[ $VERIFY_STATUS -eq 0 ]]; then
    VERIFY_JSON="$OUT"
    MATCHED_IDENTITY="$IDENTITY"
    break
  fi
done

case "$VERIFY_STATUS" in
  0)  RESULT="통과(PASS)";                              EXIT_CODE=0 ;;
  10) RESULT="거부 - 서명 없음";                         EXIT_CODE=2 ;;
  12) RESULT="거부 - 서명은 있으나 identity 불일치";      EXIT_CODE=3 ;;
  *)  RESULT="오류 (cosign exit $VERIFY_STATUS)";        EXIT_CODE=1 ;;
esac

SIGN_SUBJECT=""; SIGN_TRIGGER=""; SIGN_SHA=""
if [[ $VERIFY_STATUS -eq 0 ]]; then
  echo "✅ 서명 검증 통과"
  SIGN_SUBJECT="$(echo "$VERIFY_JSON" | jq -r '.[0].optional.Subject // "?"' 2>/dev/null)"
  SIGN_TRIGGER="$(echo "$VERIFY_JSON" | jq -r '.[0].optional.githubWorkflowTrigger // "?"' 2>/dev/null)"
  SIGN_SHA="$(echo "$VERIFY_JSON" | jq -r '.[0].optional.githubWorkflowSha // "?"' 2>/dev/null)"
  echo "  서명 subject : $SIGN_SUBJECT"
  echo "  트리거       : $SIGN_TRIGGER"
  echo "  워크플로 SHA : $SIGN_SHA"
else
  echo "⚠️  서명 검증 실패: $RESULT"
  case "$VERIFY_STATUS" in
    10) echo "    서명이 아예 없습니다. 미서명 이미지(B-1)라면 '예상된 거부'입니다." ;;
    12) echo "    서명은 있으나 허용한 identity가 아닙니다. --branch 값을 확인하거나, PR/다른 브랜치 서명인지 확인하세요." ;;
    *)  echo "    서명 유무와 무관한 오류일 수 있습니다. 아래 cosign 출력을 확인하세요." ;;
  esac
  echo "----- cosign 에러 (첫 줄) -----"
  head -n 1 "$ERR_FILE"
  echo "-------------------------------"
fi

# ── 4. 다이제스트 확보 ─────────────────────────────────────
echo "▶ 4. 다이제스트 확보"
DIGEST="$(crane digest "$IMAGE" 2>/dev/null)"
if [[ -z "$DIGEST" ]]; then
  echo "❌ 다이제스트를 가져오지 못했습니다 — 이미지 참조가 올바른지 확인하세요." >&2
  exit 1
fi
echo "  다이제스트: $DIGEST"

# ── 5. Rekor 조회 (검증 JSON의 logIndex 사용) ──────────────
# Cosign 서명 엔트리는 이미지 digest로 검색되지 않으므로,
# 검증 결과에 포함된 logIndex로 직접 조회한다. (검증 통과 시에만 가능)
echo "▶ 5. Rekor 엔트리 조회"
REKOR_SUMMARY="해당 없음 (검증 통과 시에만 조회)"
if [[ $VERIFY_STATUS -eq 0 ]]; then
  LOG_INDEX="$(echo "$VERIFY_JSON" | jq -r '.[0].optional.Bundle.Payload.logIndex // empty' 2>/dev/null)"
  INTEGRATED="$(echo "$VERIFY_JSON" | jq -r '.[0].optional.Bundle.Payload.integratedTime // empty | todate' 2>/dev/null)"
  if [[ -z "$LOG_INDEX" ]]; then
    REKOR_SUMMARY="없음 (검증 결과에 logIndex가 없음)"
    echo "⚠️  검증 결과에 Rekor logIndex가 없습니다 (번들 형식이 다를 수 있음)."
  else
    echo "  logIndex: $LOG_INDEX / 기록 시각(UTC): ${INTEGRATED:-?}"
    if REKOR_OUT="$(rekor-cli get --log-index "$LOG_INDEX" --format json 2>&1)"; then
      echo "$REKOR_OUT" | jq . 2>/dev/null || echo "$REKOR_OUT"
      REKOR_SUMMARY="있음 (logIndex $LOG_INDEX, ${INTEGRATED:-?})"
    else
      echo "⚠️  Rekor 조회 실패 (네트워크/서버 확인):"
      echo "$REKOR_OUT"
      REKOR_SUMMARY="조회 실패 (logIndex $LOG_INDEX는 검증 결과에 있음)"
    fi
  fi
else
  echo "  검증이 통과하지 않아 Rekor 조회를 건너뜁니다."
fi

# ── 결과 요약 (기록표용) ───────────────────────────────────
echo ""
echo "===== 요약 ====="
echo "이미지        : $IMAGE"
echo "다이제스트     : $DIGEST"
echo "검증 기준      : ${BRANCHES[*]}"
echo "검증 결과      : $RESULT"
[[ -n "$SIGN_SUBJECT" ]] && echo "서명 subject  : $SIGN_SUBJECT"
echo "Rekor 엔트리   : $REKOR_SUMMARY"
echo "종료 코드      : $EXIT_CODE"
echo "================="

exit "$EXIT_CODE"
