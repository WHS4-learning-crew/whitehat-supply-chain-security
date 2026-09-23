#!/bin/sh
# C-3: 휴면 후 외부(내부 통제) 아웃바운드 연결 재현
# 안전 원칙: 실제 C2 서버가 아닌, 팀이 통제하는 클러스터 내부 엔드포인트로만 연결

DORMANT_SECONDS=300   # 5분 휴면
TARGET="http://c3-beacon-receiver.ns-kimseoyeon.svc.cluster.local:8080/beacon"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pod started, entering dormant period (${DORMANT_SECONDS}s)"
sleep "$DORMANT_SECONDS"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dormant period over, sending beacon"
curl -sS -m 5 "$TARGET"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] beacon sent, exiting"
