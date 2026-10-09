#!/usr/bin/env bash
#
# scripts/run-build-verify.sh
#
# build job(app/Dockerfile)이 CI에 올라가기 전, 로컬에서
# 빌드 -> 헬스체크 -> 비-root 실행 확인까지 한 번에 검증하는 스크립트.
#
# 실행 위치: 레포 루트 (whitehat-supply-chain-security/)
#
# 사전 조건:
#   1. Docker Desktop 실행 중
#   2. 호스트의 3000번 포트가 비어 있어야 함
#      (사용 중이면 스크립트가 시작 단계에서 안내 후 종료)
#      다른 포트를 쓰려면 HOST_PORT 환경변수로 지정:
#        HOST_PORT=3001 ./scripts/run-build-verify.sh
#   3. curl 설치 (macOS 기본 포함)
#
# 사용법:
#   ./scripts/run-build-verify.sh
#
# 종료 코드:
#   0: 빌드/헬스체크/비-root 확인 모두 통과
#   1: 사전 조건 미충족 또는 검증 실패 (메시지 확인)
#
set -euo pipefail

IMAGE_NAME="whitehat-demo"
IMAGE_TAG="local-verify"
CONTAINER_NAME="whitehat-demo-verify"
APP_DIR="app"
CONTAINER_PORT=3000                 # 앱이 컨테이너 안에서 사용하는 포트 (고정)
HOST_PORT="${HOST_PORT:-3000}"      # 호스트에서 열 포트 (충돌 시 변경 가능)
HEALTH_URL="http://localhost:${HOST_PORT}/health"
MAX_WAIT_SECONDS=15

log() { printf '\n[run-build-verify] %s\n' "$1"; }

cleanup() {
  log "정리: 컨테이너 중지/삭제"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- 0. 사전 조건 점검 ----
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon에 연결할 수 없습니다. Docker Desktop이 실행 중인지 확인하세요." >&2
  exit 1
fi

if [ ! -f "${APP_DIR}/Dockerfile" ]; then
  echo "${APP_DIR}/Dockerfile을 찾을 수 없습니다. 레포 루트에서 실행했는지 확인하세요." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl 명령어가 필요합니다. 설치 후 다시 실행하세요." >&2
  exit 1
fi

# 이전 실행에서 남은 컨테이너가 포트를 잡고 있을 수 있으므로 먼저 정리
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# 호스트 포트 사용 여부 확인 (lsof가 없으면 건너뛰고 docker run 단계에서 판단)
if command -v lsof >/dev/null 2>&1; then
  if lsof -iTCP:"${HOST_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "호스트의 ${HOST_PORT}번 포트가 이미 사용 중입니다." >&2
    echo "해당 프로세스를 종료하거나, 다른 포트로 실행하세요: HOST_PORT=3001 ./scripts/run-build-verify.sh" >&2
    echo "--- 포트를 사용 중인 프로세스 ---" >&2
    lsof -iTCP:"${HOST_PORT}" -sTCP:LISTEN >&2 || true
    exit 1
  fi
else
  log "경고: lsof가 없어 포트 사용 여부를 사전 확인하지 못했습니다."
fi

# ---- 1. 이미지 빌드 ----
log "1/3 이미지 빌드: ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "${APP_DIR}"

# ---- 2. 컨테이너 기동 + 헬스체크 ----
log "2/3 컨테이너 기동 및 헬스체크 (호스트 ${HOST_PORT} -> 컨테이너 ${CONTAINER_PORT})"
docker run -d --name "$CONTAINER_NAME" -p "${HOST_PORT}:${CONTAINER_PORT}" "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null

healthy=false
for i in $(seq 1 "$MAX_WAIT_SECONDS"); do
  if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 1
done

if [ "$healthy" != "true" ]; then
  echo "헬스체크 실패: ${MAX_WAIT_SECONDS}초 내에 ${HEALTH_URL} 응답 없음" >&2
  echo "--- 컨테이너 로그 ---" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
fi

HEALTH_RESPONSE=$(curl -s "$HEALTH_URL")
log "헬스체크 통과: $HEALTH_RESPONSE"

# ---- 3. 비-root 실행 확인 ----
log "3/3 비-root 실행 확인"
RUNTIME_USER=$(docker exec "$CONTAINER_NAME" whoami)
if [ "$RUNTIME_USER" = "root" ]; then
  echo "컨테이너가 root로 실행 중입니다. Dockerfile의 USER 지시문을 확인하세요." >&2
  exit 1
fi
log "비-root 실행 확인됨: 실행 계정 = ${RUNTIME_USER}"

log "전체 통과 — 이미지 ${IMAGE_NAME}:${IMAGE_TAG} 는 빌드/헬스체크/비-root 조건을 모두 만족합니다."
