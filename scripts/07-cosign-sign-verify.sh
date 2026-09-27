#!/usr/bin/env bash
#
# 07-cosign-sign-verify.sh
#
# 목적: ECR에 올라간 이미지를 대상으로
#   1) Cosign Keyless 서명 (선택, --sign)
#   2) 서명 검증 (identity/issuer 대조)
#   3) Rekor 투명성 로그 조회
# 를 한 번에 재현 가능하게 수행한다.
#
# 사용법:
#   ./07-cosign-sign-verify.sh <image-ref> [--sign] [--branch <branch-name>]
#
# 예시:
#   # 정상 서명된 이미지 검증 (main 브랜치 기준)
#   ./07-cosign-sign-verify.sh 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/whs4-demo-app:main
#
#   # feat/ci-pipeline 브랜치에서 빌드된 이미지 검증
#   ./07-cosign-sign-verify.sh 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/whs4-demo-app:feat --branch feat/ci-pipeline
#
#   # B-1: 미서명 이미지가 "정상적으로 거부"되는지 확인 (exit code 2 = 예상된 거부)
#   ./07-cosign-sign-verify.sh 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/whs4-bypass:v1.0
#
# 기본 동작은 verify + rekor 조회만 수행한다. CI 밖에서 sign을 실제로 하면
# 새로운 서명 이벤트가 추가되어 팀 기록과 어긋날 수 있으므로,
# 서명까지 재현하려면 --sign 옵션을 명시적으로 붙인다.
#
# 주의: --sign을 CI(GitHub Actions) 밖, 즉 로컬에서 실행하면 브라우저 기반
# OIDC 로그인이 뜨고 서명자의 identity가 "개인 계정"이 된다. 이 경우 아래
# CERT_IDENTITY(워크플로 경로 기준)로는 검증이 절대 통과하지 않는다.
# 이는 스크립트 오류가 아니라 keyless 서명의 정상 동작이므로, 로컬 서명 후
# 검증까지 통과시키려면 --certificate-identity를 본인 이메일 등으로 별도
# 지정해서 확인해야 한다. (팀 파이프라인 identity 값과는 별개로 확인 용도)

set -uo pipefail
# 주: cosign verify 실패(=미서명/미매칭)를 "스크립트 크래시"가 아니라
# "예상된 결과"로 다루기 위해 set -e는 사용하지 않는다. 대신 각 명령의
# 종료 코드를 그때그때 직접 확인한다.

# ── 설정값 (필요 시 이 부분만 수정) ─────────────────────────
AWS_REGION="ap-northeast-2"
REPO_PATH="WHS4-learning-crew/whitehat-supply-chain-security/.github/workflows/ci-pipeline.yml"
CERT_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# 워크플로 트리거 브랜치: main, feat/ci-pipeline 둘 다 CI를 태우므로
# 어느 브랜치에서 빌드된 이미지인지에 따라 identity 문자열이 달라진다.
# 기본값은 main. 다른 브랜치 이미지를 검증할 때는 --branch로 지정한다.
DEFAULT_BRANCH="main"

# ── 인자 처리 ──────────────────────────────────────────────
IMAGE="${1:?사용법: $0 <image-ref> [--sign] [--branch <branch-name>]}"
shift

DO_SIGN=""
BRANCH="$DEFAULT_BRANCH"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)
      DO_SIGN="--sign"
      shift
      ;;
    --branch)
      BRANCH="${2:?--branch 옵션에는 브랜치명이 필요합니다}"
      shift 2
      ;;
    *)
      echo "❌ 알 수 없는 옵션: $1" >&2
      exit 1
      ;;
  esac
done

CERT_IDENTITY="https://github.com/${REPO_PATH}@refs/heads/${BRANCH}"
REGISTRY="$(echo "$IMAGE" | cut -d'/' -f1)"

echo "ℹ️  검증 기준 identity: $CERT_IDENTITY"

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
  echo "⚠️  로컬 환경에서 서명 시 identity가 워크플로 경로가 아닌 개인 계정으로 기록됩니다."
  echo "    아래 3번 검증 단계는 CERT_IDENTITY(워크플로 기준)와 대조하므로 실패가 예상됩니다."
  COSIGN_EXPERIMENTAL=1 cosign sign --yes "$IMAGE"
else
  echo "▶ 2. 서명 단계 건너뜀 (재현하려면 --sign 옵션 추가)"
fi

# ── 3. 서명 검증 ───────────────────────────────────────────
echo "▶ 3. 서명 검증"
VERIFY_OUTPUT="$(cosign verify \
  --certificate-identity="$CERT_IDENTITY" \
  --certificate-oidc-issuer="$CERT_OIDC_ISSUER" \
  "$IMAGE" 2>&1)"
VERIFY_STATUS=$?

if [[ $VERIFY_STATUS -eq 0 ]]; then
  echo "✅ 서명 검증 통과"
  echo "$VERIFY_OUTPUT" | jq . 2>/dev/null || echo "$VERIFY_OUTPUT"
else
  echo "⚠️  서명 검증 실패 (exit $VERIFY_STATUS)"
  echo "    미서명 이미지(B-1 등)에 대한 테스트라면 이는 '예상된 거부'입니다."
  echo "    서명된 이미지인데 실패했다면 --branch 값 또는 identity/issuer 값을 확인하세요."
  echo "----- cosign 출력 -----"
  echo "$VERIFY_OUTPUT"
  echo "-----------------------"
fi

# ── 4. 다이제스트 확보 ─────────────────────────────────────
echo "▶ 4. 다이제스트 확보"
DIGEST="$(crane digest "$IMAGE" 2>/dev/null)"
if [[ -z "$DIGEST" ]]; then
  echo "❌ 다이제스트를 가져오지 못했습니다 — 이미지 참조가 올바른지 확인하세요." >&2
  exit 1
fi
echo "  다이제스트: $DIGEST"

# ── 5. Rekor 로그 조회 ─────────────────────────────────────
echo "▶ 5. Rekor 검색"
UUIDS="$(rekor-cli search --sha256 "${DIGEST#sha256:}" 2>/dev/null || true)"
echo "$UUIDS"

if [[ -n "$UUIDS" ]]; then
  echo "▶ 6. 상세 엔트리 조회 (검색된 UUID 각각)"
  echo "$UUIDS" | while read -r uuid; do
    [[ -z "$uuid" ]] && continue
    echo "── UUID: $uuid ──"
    rekor-cli get --uuid "$uuid" --format json | jq .
  done
else
  echo "⚠️  검색 결과 없음 — 서명이 아직 안 됐거나 다이제스트가 다를 수 있습니다."
fi

# ── 결과 요약 (기록표용) ───────────────────────────────────
echo ""
echo "===== 요약 ====="
echo "이미지        : $IMAGE"
echo "identity      : $CERT_IDENTITY"
echo "검증 결과      : $([[ $VERIFY_STATUS -eq 0 ]] && echo '통과(PASS)' || echo '거부(REJECTED)')"
echo "Rekor 엔트리   : $([[ -n "$UUIDS" ]] && echo '있음' || echo '없음')"
echo "================="

# 검증 실패(=미서명/미매칭)는 크래시가 아니라 "정상적으로 관측된 결과"이므로
# exit 2로 구분해서 반환한다. (0=서명 검증 통과, 2=검증 거부, 1=그 외 오류)
if [[ $VERIFY_STATUS -eq 0 ]]; then
  exit 0
else
  exit 2
fi
