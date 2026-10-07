#!/usr/bin/env bash
# scripts/check-policy-health.sh
# "정책이 있다"가 아니라 "정책이 집행되고 있다"를 확인한다.
#
# 배경: B-1에서 서명 검증 정책은 Ready로 보였지만 webhook이 등록되지 않아
#       미서명 이미지가 그대로 통과했다. kubectl get의 상태 표시만으로는 알 수 없었다.
# 방식: 상태 조건 / webhook 등록 / 컨트롤러 오류 로그 / 실제 거부 여부를 함께 본다.
#       마지막 항목(서버 dry-run)은 파드를 만들지 않고 admission을 실제로 통과시켜 본다.
#
# 사용:  AWS_ACCOUNT_ID=<계정ID> ./scripts/check-policy-health.sh
# 종료 코드: 0 = 모두 정상, 1 = 하나 이상 실패 (발표 전·당일 아침 실행 권장)

set -uo pipefail

TEST_NS="${TEST_NS:-ns-kwonminchan}"
REGION="${REGION:-ap-northeast-2}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
LOG_WINDOW="${LOG_WINDOW:-30m}"
EXTERNAL_IMAGE="${EXTERNAL_IMAGE:-busybox:1.36}"

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
step() { printf '\n\033[1;34m[%s]\033[0m %s\n' "$1" "$2"; }

step "0" "사전 확인"
for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  $cmd 가 필요합니다"; exit 2; }
done
if [ -z "$AWS_ACCOUNT_ID" ] && command -v aws >/dev/null 2>&1; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
fi
[ -n "$AWS_ACCOUNT_ID" ] || { echo "  AWS_ACCOUNT_ID 를 환경변수로 지정하세요"; exit 2; }
ECR="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
UNSIGNED_IMAGE="${UNSIGNED_IMAGE:-${ECR}/whs4-bypass:v1.0}"
SIGNED_IMAGE="${SIGNED_IMAGE:-${ECR}/whs4-demo-app:b8efcd18e19699502ab8b075d6bd929a1bde2e79}"
kubectl get ns "$TEST_NS" >/dev/null 2>&1 || { echo "  네임스페이스 $TEST_NS 접근 불가"; exit 2; }
echo "  테스트 네임스페이스: $TEST_NS"

# ---------------------------------------------------------------
step "1" "ClusterPolicy 상태"
if cp_json="$(kubectl get clusterpolicy -o json 2>/dev/null)"; then
  n_cp="$(jq '.items | length' <<<"$cp_json")"
  bad_cp="$(jq -r '.items[] | select(
      ((.status.ready // false) != true) and
      (((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "") != "True")
    ) | .metadata.name' <<<"$cp_json")"
  if [ -z "$bad_cp" ]; then pass "ClusterPolicy ${n_cp}개 모두 Ready"
  else fail "Ready가 아닌 ClusterPolicy: $(echo "$bad_cp" | tr '\n' ' ')"; fi
else
  fail "ClusterPolicy 조회 실패"
fi

# ---------------------------------------------------------------
step "2" "ImageValidatingPolicy 상태 (WebhookConfigured 포함)"
if ivp_json="$(kubectl get imagevalidatingpolicy -o json 2>/dev/null)"; then
  n_ivp="$(jq '.items | length' <<<"$ivp_json")"
  bad_ivp="$(jq -r '.items[] | select(
      ((.status.conditionStatus.ready // false) != true) or
      (((.status.conditionStatus.conditions // []) | map(select(.type=="WebhookConfigured")) | .[0].status // "") != "True")
    ) | .metadata.name' <<<"$ivp_json")"
  if [ -z "$bad_ivp" ]; then pass "ImageValidatingPolicy ${n_ivp}개 모두 Ready, WebhookConfigured=True"
  else fail "Ready 또는 WebhookConfigured가 아닌 정책: $(echo "$bad_ivp" | tr '\n' ' ')"; fi
else
  n_ivp=0
  warn "ImageValidatingPolicy를 조회할 수 없습니다 (CRD 없음 또는 권한 부족)"
fi

# ---------------------------------------------------------------
step "3" "서명 검증 webhook 등록 여부"
if wh_json="$(kubectl get validatingwebhookconfiguration -o json 2>/dev/null)"; then
  n_wh="$(jq '[.items[].webhooks[]?.name | select(startswith("ivpol"))] | length' <<<"$wh_json")"
  if [ "${n_ivp:-0}" -gt 0 ] && [ "$n_wh" -eq 0 ]; then
    fail "정책은 ${n_ivp}개 있으나 ivpol webhook이 없음 (정책이 집행되지 않는 상태)"
  else
    pass "ivpol webhook ${n_wh}개 등록"
  fi
else
  fail "ValidatingWebhookConfiguration 조회 실패"
fi

# ---------------------------------------------------------------
step "4" "Kyverno 컨트롤러 webhook 오류 로그 (최근 ${LOG_WINDOW})"
if logs="$(kubectl logs -n kyverno deploy/kyverno-admission-controller --since="$LOG_WINDOW" 2>/dev/null)"; then
  err_cnt="$(grep -cE 'ValidatingWebhookConfiguration.*is invalid' <<<"$logs" || true)"
  if [ "${err_cnt:-0}" -eq 0 ]; then pass "webhook 설정 오류 없음"
  else fail "webhook 설정 오류 ${err_cnt}건 (예: timeoutSeconds 상한 30초 초과)"; fi
else
  warn "admission-controller 로그를 읽을 수 없습니다"
fi

# ---------------------------------------------------------------
dry_run_pod() { # $1=파드 이름, $2=이미지 — 파드를 생성하지 않고 admission만 거친다
  cat <<EOF | kubectl apply --dry-run=server -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $TEST_NS
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 1000 }
  containers:
    - name: app
      image: $2
      command: ["sleep", "60"]
      securityContext: { runAsNonRoot: true, allowPrivilegeEscalation: false }
EOF
}

expect_denied() { # $1=설명, $2=이미지, $3=거부 사유로 기대하는 정책 이름
  local out rc
  out="$(dry_run_pod "health-$RANDOM" "$2")"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$3" <<<"$out"; then
    pass "$1 → $3 정책이 거부"
  elif [ "$rc" -ne 0 ]; then
    fail "$1 → 거부되었으나 사유가 $3 가 아님 (출력 확인 필요)"
    echo "$out" | head -3 | sed 's/^/        /'
  else
    fail "$1 → 거부되지 않고 통과함 (정책이 집행되지 않음)"
  fi
}

expect_allowed() { # $1=설명, $2=이미지
  local out rc
  out="$(dry_run_pod "health-$RANDOM" "$2")"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "$1 → 정상 통과"
  else
    fail "$1 → 정상 이미지가 거부됨 (서명 identity 불일치 또는 서명 누락 가능)"
    echo "$out" | head -3 | sed 's/^/        /'
  fi
}

step "5" "실제 집행 확인 (서버 dry-run, 파드는 생성되지 않음)"
expect_denied  "미서명 이미지(CI 우회)"      "$UNSIGNED_IMAGE" "verify-image-signature"
expect_denied  "외부 레지스트리 이미지"      "$EXTERNAL_IMAGE" "restrict-image-registries"
expect_allowed "서명된 정상 이미지(대조군)"  "$SIGNED_IMAGE" 

# ---------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m정책 점검 통과\033[0m — 모든 항목 정상\n'
  exit 0
else
  printf '\033[1;31m정책 점검 실패\033[0m — %d개 항목 확인 필요\n' "$FAIL"
  exit 1
fi
