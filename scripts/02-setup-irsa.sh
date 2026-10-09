#!/usr/bin/env bash
# scripts/02-setup-irsa.sh
# IRSA(IAM Roles for Service Accounts) 5단계를 한 번에 구성하고 검증한다.
#
#   ① OIDC 공급자 연결   ② IAM Policy   ③ IAM Role + 신뢰 정책
#   ④ 서비스어카운트 연결   ⑤ 파드에서 실제 조회로 검증
#
# 사전 도구: aws, kubectl, eksctl
#   설치: brew install awscli kubectl eksctl
#
# 사용 예:
#   NAMESPACE=ns-kwonminchan SECRET_NAME=whitehat/test-secret ./scripts/02-setup-irsa.sh
#
# 여러 번 실행해도 안전하다(멱등). 이미 있는 리소스는 건너뛰거나 갱신한다.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-whitehat-eks}"
REGION="${REGION:-ap-northeast-2}"
NAMESPACE="${NAMESPACE:?NAMESPACE를 지정하세요 (예: ns-kwonminchan)}"
SA_NAME="${SA_NAME:-secrets-reader}"
SECRET_NAME="${SECRET_NAME:?SECRET_NAME을 지정하세요 (예: whitehat/test-secret)}"
ROLE_NAME="${ROLE_NAME:-whs4-${NAMESPACE}-${SA_NAME}}"
POLICY_NAME="${POLICY_NAME:-${ROLE_NAME}-policy}"
VERIFY="${VERIFY:-true}"
VERIFY_IMAGE="${VERIFY_IMAGE:-amazon/aws-cli:2.17.0}"

log()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

TMPDIR_IRSA="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_IRSA"' EXIT

log "0/5" "사전 확인"
for cmd in aws kubectl eksctl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd 가 설치되어 있지 않습니다"
done
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "네임스페이스 $NAMESPACE 가 없거나 접근 권한이 없습니다"
ok "계정 ${ACCOUNT_ID} / 클러스터 ${CLUSTER_NAME} / 대상 ${NAMESPACE}:${SA_NAME}"

log "1/5" "OIDC 공급자"
ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text)"
OIDC_HOST="${ISSUER#https://}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
if OIDC_OUT="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" 2>&1)"; then
  ok "이미 연결됨 (${OIDC_HOST##*/})"
elif grep -q "NoSuchEntity" <<<"$OIDC_OUT"; then
  # 공급자가 없는 경우에만 새로 만든다
  eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" --region "$REGION" --approve >/dev/null
  ok "새로 연결함 (${OIDC_HOST##*/})"
else
  # 권한·자격증명·네트워크 오류는 "없음"과 구분해서 멈춘다 (오류 코드만 표시, ARN은 출력하지 않음)
  OIDC_ERR="$(sed -n 's/.*An error occurred (\([A-Za-z]*\)).*/\1/p' <<<"$OIDC_OUT" | head -n1)"
  fail "OIDC 공급자 조회에 실패했습니다 (오류 코드: ${OIDC_ERR:-알 수 없음}). 권한(iam:GetOpenIDConnectProvider), 자격증명, 네트워크를 확인하세요"
fi

log "2/5" "IAM Policy"
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
  --region "$REGION" --query ARN --output text)" \
  || fail "시크릿 $SECRET_NAME 을 찾을 수 없습니다"
cat > "$TMPDIR_IRSA/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "${SECRET_ARN}"
  }]
}
EOF
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  VERSION_COUNT="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
    --query "length(Versions)" --output text)"
  if [ "$VERSION_COUNT" -ge 5 ]; then
    OLDEST="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query "sort_by(Versions[?IsDefaultVersion==\`false\`], &CreateDate)[0].VersionId" \
      --output text)"
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
  fi
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://$TMPDIR_IRSA/policy.json" --set-as-default >/dev/null
  ok "기존 정책 갱신 (새 버전을 기본값으로 지정)"
else
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://$TMPDIR_IRSA/policy.json" >/dev/null
  ok "새 정책 생성"
fi
ok "허용 대상: ${SECRET_ARN##*:secret:}"

log "3/5" "IAM Role + 신뢰 정책"
cat > "$TMPDIR_IRSA/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}"
      }
    }
  }]
}
EOF
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$TMPDIR_IRSA/trust.json"
  ok "기존 Role의 신뢰 정책 갱신"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMPDIR_IRSA/trust.json" >/dev/null
  ok "새 Role 생성"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
ok "신뢰 대상: system:serviceaccount:${NAMESPACE}:${SA_NAME}"

log "4/5" "서비스어카운트"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl annotate serviceaccount "$SA_NAME" -n "$NAMESPACE" \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}" --overwrite >/dev/null
ok "${NAMESPACE}/${SA_NAME} → ${ROLE_NAME}"

if [ "$VERIFY" != "true" ]; then
  log "5/5" "검증 생략 (VERIFY=false)"
  exit 0
fi

log "5/5" "파드에서 조회 검증"
POD="irsa-verify-$(date +%s)"
cleanup_pod() { kubectl delete pod "$POD" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap 'cleanup_pod; rm -rf "$TMPDIR_IRSA"' EXIT
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: aws-cli
      image: ${VERIFY_IMAGE}
      command: ["sleep", "300"]
      env:
        - name: HOME
          value: /tmp
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
EOF
kubectl wait --for=condition=Ready "pod/${POD}" -n "$NAMESPACE" --timeout=120s >/dev/null \
  || fail "검증 파드가 준비되지 않았습니다 (kubectl describe pod ${POD} -n ${NAMESPACE} 확인)"
for i in 1 2 3 4 5 6; do
  if RESULT="$(kubectl exec "$POD" -n "$NAMESPACE" -- \
      aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
      --region "$REGION" --query Name --output text 2>&1)"; then
    ok "조회 성공: ${RESULT} (액세스 키 없이 IRSA 임시 자격증명으로 인증)"
    exit 0
  fi
  sleep 5
done
printf '%s\n' "$RESULT" >&2
fail "조회 실패 — 위 에러 메시지를 확인하세요"
