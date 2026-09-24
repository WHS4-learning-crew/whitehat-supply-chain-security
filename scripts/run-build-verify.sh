#!/usr/bin/env bash
#
# scripts/run-build-verify.sh
#
# build job(app/Dockerfile)이 CI에 올라가기 전, 로컬에서
# 빌드 -> 헬스체크 -> 비-root 실행 확인까지 한 번에 검증하는 스크립트.
#
# 실행 위치: 레포 루트 (whitehat-supply-chain-security/)
# 사전 조건: Docker Desktop 실행 중
#
# 사용법:
#   ./scripts/run-build-verify.sh
#
set -euo pipefail

IMAGE_NAME="whitehat-demo"
IMAGE_TAG="local-verify"
CONTAINER_NAME="whitehat-demo-verify"
APP_DIR="app"
PORT=3000
HEALTH_URL="http://localhost:${PORT}/health"
MAX_WAIT_SECONDS=15

log() { printf '\n[run-build-verify] %s\n' "$1"; }

cleanup() {
  log "정리: 컨테이너 중지/삭제"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon에 연결할 수 없습니다. Docker Desktop이 실행 중인지 확인하세요." >&2
  exit 1
fi

if [ ! -f "${APP_DIR}/Dockerfile" ]; then
  echo "${APP_DIR}/Dockerfile을 찾을 수 없습니다. 레포 루트에서 실행했는지 확인하세요." >&2
  exit 1
fi

# ---- 1. 이미지 빌드 ----
log "1/3 이미지 빌드: ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "${APP_DIR}"

# ---- 2. 컨테이너 기동 + 헬스체크 ----
log "2/3 컨테이너 기동 및 헬스체크"
cleanup  # 혹시 이전 실행 잔여물이 남아있으면 먼저 정리
docker run -d --name "$CONTAINER_NAME" -p "${PORT}:${PORT}" "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null

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
  echo "컨테이너가 root로 실행 중입니다 (기대값: node). Dockerfile의 USER 지시문을 확인하세요." >&2
  exit 1
fi
log "비-root 실행 확인됨: 실행 계정 = ${RUNTIME_USER}"

log "전체 통과 — 이미지 ${IMAGE_NAME}:${IMAGE_TAG} 는 빌드/헬스체크/비-root 조건을 모두 만족합니다."
