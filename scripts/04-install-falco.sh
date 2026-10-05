#!/bin/bash
#
# scripts/04-install-falco.sh
#
# Falco + Falcosidekick(Discord 알림) 설치/업그레이드 자동화 스크립트
# 담당: 성유정 (런타임 탐지, C그룹)
#
# 사용 전 준비물:
#   1. kubeconfig가 대상 EKS 클러스터(whitehat-eks)를 가리키고 있어야 함
#      → aws eks update-kubeconfig --name whitehat-eks --region ap-northeast-2
#   2. Discord Webhook URL을 환경변수로 미리 설정해둘 것 (커밋 금지, 하드코딩 금지)
#      → export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
#   3. falco-rules/values.yaml 이 이 스크립트와 같은 저장소 구조 내에 있어야 함
#      (customRules: rules-teamtnt.yaml / rules-exceptions.yaml /
#                     c3-dormant-outbound.yaml / c4-credential-exfil.yaml 포함)
#
# 실행:
#   chmod +x scripts/04-install-falco.sh
#   ./scripts/04-install-falco.sh
#
# 재실행해도 안전함(helm upgrade --install 사용) — 이미 설치돼 있으면 설정만 갱신됨.

set -euo pipefail

NAMESPACE="falco"
RELEASE_NAME="falco"
VALUES_FILE="$(dirname "$0")/../falco-rules/values.yaml"

echo "=== [1/5] 사전 조건 확인 ==="

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  echo "에러: DISCORD_WEBHOOK_URL 환경변수가 설정되어 있지 않습니다."
  echo "      export DISCORD_WEBHOOK_URL=\"https://discord.com/api/webhooks/...\" 실행 후 다시 시도하세요."
  exit 1
fi

if ! command -v helm &> /dev/null; then
  echo "에러: helm이 설치되어 있지 않습니다."
  exit 1
fi

if ! command -v kubectl &> /dev/null; then
  echo "에러: kubectl이 설치되어 있지 않습니다."
  exit 1
fi

if [ ! -f "$VALUES_FILE" ]; then
  echo "에러: values.yaml 파일을 찾을 수 없습니다: $VALUES_FILE"
  echo "      스크립트를 scripts/ 디렉토리에서 실행 중인지, falco-rules/values.yaml이 존재하는지 확인하세요."
  exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
  echo "에러: kubectl이 클러스터에 연결되지 않습니다. kubeconfig를 확인하세요."
  exit 1
fi

echo "사전 조건 확인 완료."

echo ""
echo "=== [2/5] Helm 저장소 등록·업데이트 ==="
helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update

echo ""
echo "=== [3/5] Falco 설치/업그레이드 ==="
echo "release: $RELEASE_NAME / namespace: $NAMESPACE"
echo "values: $VALUES_FILE"
echo "(Discord Webhook URL은 로그에 노출되지 않도록 --set으로만 주입합니다)"

helm upgrade --install "$RELEASE_NAME" falcosecurity/falco \
  -n "$NAMESPACE" --create-namespace \
  -f "$VALUES_FILE" \
  --set falcosidekick.config.discord.webhookurl="$DISCORD_WEBHOOK_URL" \
  --set falcosidekick.config.discord.minimumpriority="warning"

echo ""
echo "=== [4/5] Pod 기동 대기 ==="
echo "falco DaemonSet Pod가 Running 상태가 될 때까지 최대 120초 대기합니다..."
if kubectl rollout status daemonset/"$RELEASE_NAME" -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
  echo "falco DaemonSet 기동 완료."
else
  echo "경고: 120초 내에 확인되지 않았습니다. 아래 명령으로 직접 상태를 확인하세요:"
  echo "  kubectl get pods -n $NAMESPACE"
fi

echo ""
echo "=== [5/5] 룰 로드 검증 ==="
FALCO_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=falco -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$FALCO_POD" ]; then
  echo "Pod $FALCO_POD 기준 룰 파일 로드 상태:"
  kubectl logs "$FALCO_POD" -n "$NAMESPACE" -c falco 2>/dev/null \
    | grep -i "schema validation" || echo "  (아직 로그가 없습니다. 잠시 후 아래 명령으로 직접 확인하세요.)"
else
  echo "falco Pod를 아직 찾지 못했습니다. 아래 명령으로 직접 확인하세요:"
fi

echo ""
echo "=== 완료 ==="
echo "상태 확인:      kubectl get pods -n $NAMESPACE"
echo "룰 검증:        kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=falco -c falco | grep 'schema validation'"
echo "실시간 로그:    kubectl logs -f -n $NAMESPACE -l app.kubernetes.io/name=falco --tail=20"
echo "Discord 테스트: kubectl exec -it deployment/alpine-test -n ns-sungyujeong -- sh"
echo "                  echo '#!/bin/sh' > /tmp/nmap && echo 'sleep 3' >> /tmp/nmap && chmod +x /tmp/nmap && /tmp/nmap"
