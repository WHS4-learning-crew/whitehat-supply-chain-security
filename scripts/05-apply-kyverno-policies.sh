#!/bin/bash
#
# Kyverno 정책 적용 스크립트
# 사용법: ./scripts/05-apply-kyverno-policies.sh <네임스페이스>
#
# [실행 방법]
# 1. 실행 권한 부여 (처음 한 번만)
#    chmod +x scripts/05-apply-kyverno-policies.sh
# 2. 실행 (네임스페이스 지정)
#    ./scripts/05-apply-kyverno-policies.sh ns-parkseonghyeon
#    ./scripts/05-apply-kyverno-policies.sh ns-jeongjihyun
#
# [적용되는 정책]
# - verify-image-signature.yaml    : ECR 이미지 서명 검증 (서명 없으면 배포 차단)
# - disallow-root-user.yaml        : root 컨테이너 실행 차단 (ClusterPolicy)
# - restrict-image-registries.yaml : 허용된 ECR 레지스트리 외 이미지 차단 (ClusterPolicy)
# - falco-exception.yaml           : Falco 네임스페이스 root 실행 예외 처리
#
# [주의]
# - kubectl이 EKS 클러스터에 연결된 상태여야 함
# - falco 네임스페이스 apply 권한 필요 (PM에게 요청)
#

set -e

NAMESPACE="${1:?사용법: $0 <네임스페이스> (예: ns-parkseonghyeon)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$SCRIPT_DIR/../policies"

echo "======================================"
echo " Kyverno 정책 적용 스크립트"
echo " 네임스페이스: $NAMESPACE"
echo "======================================"
echo ""

# 1. 이미지 서명 검증 정책 적용
echo "[1/5] 이미지 서명 검증 정책 적용 중..."
kubectl apply -f "$POLICIES_DIR/verify-image-signature.yaml"
echo ""

# 2. ClusterPolicy 적용 (disallow-root-user, restrict-image-registries)
echo "[2/5] ClusterPolicy 적용 중..."
kubectl apply -f "$POLICIES_DIR/disallow-root-user.yaml"
kubectl apply -f "$POLICIES_DIR/restrict-image-registries.yaml"
echo ""

# 3. 정책 상태 확인
echo "[3/5] 정책 상태 확인 중... (최대 30초 대기)"
for i in $(seq 1 6); do
  STATUS=$(kubectl get imagevalidatingpolicy verify-image-signature -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null || echo "false")
  if [ "$STATUS" = "true" ]; then
    echo "✓ verify-image-signature READY"
    break
  fi
  echo "  대기 중... ($((i * 5))s)"
  sleep 5
done

kubectl get imagevalidatingpolicy verify-image-signature
kubectl get clusterpolicy disallow-root-user restrict-image-registries
echo ""

# 4. Falco 예외 처리 적용
echo "[4/5] Falco 예외 처리 적용 중..."
kubectl apply -f "$POLICIES_DIR/falco-exception.yaml"
echo ""

# 5. 예외 처리 확인
echo "[5/5] 예외 처리 상태 확인..."
kubectl get policyexception -n falco
echo ""

echo "======================================"
echo " 완료!"
echo "======================================"
