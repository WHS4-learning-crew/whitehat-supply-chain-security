#!/usr/bin/env bash
#
# run-iac-scan.sh
#
# 목적:
#   CI의 IaC 보안 검사를 로컬에서 한 번에 실행
#
# 사전 준비:
#   1. 프로젝트 저장소를 내려받고 이 파일을 scripts/에 둔다.
#   2. Checkov와 tfsec를 설치한다.
#   3. Checkov를 가상환경에 설치했다면 해당 환경을 활성화한다.
#      예: source "$HOME/.venvs/checkov/bin/activate"
#
# 준비 확인:
#   checkov --version
#   tfsec --version
#
# 실행 방법 (저장소 루트에서):
#   bash scripts/run-iac-scan.sh
#   echo "종료 코드: $?"
#
# 결과 확인:
#   0: 모든 검사 통과
#   127: 필요한 도구를 찾지 못함
#   그 외: 실패한 검사 로그에서 정책 위반 또는 실행 오류 확인
#   첫 실패 시 이후 검사는 실행되지 않음
#
# 정적 검사만 수행하며 AWS 적용이나 클러스터 배포는 하지 않음

set -euo pipefail

# 실행 위치와 관계없이 저장소 루트에서 검사
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# 필요한 도구 확인
for tool in checkov tfsec; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "오류: $tool 명령어가 필요합니다. 설치 또는 가상환경 활성화를 확인하세요." >&2
    exit 127
  fi
done

# 1. Dockerfile: Checkov 기본 정책 위반 시 실패
echo "[Checkov] Dockerfile 검사"
checkov -d . --framework dockerfile --compact --quiet

# 2. Kubernetes: 저장소 내 YAML 검사 (policies/rbac/ 포함)
echo "[Checkov] Kubernetes YAML 검사"
checkov -d . --framework kubernetes --compact --quiet

# 3. GitHub Actions: 워크플로 권한 등 보안 설정 검사
echo "[Checkov] GitHub Actions 검사"
checkov -d . --framework github_actions --compact --quiet

# 4. Terraform: infra-rbac/만 검사, HIGH·CRITICAL 발견 시 실패
# eksctl·CloudFormation 기반 EKS/VPC/NodeGroup은 이 검사 범위에서 제외
echo "[tfsec] infra-rbac/ 검사: HIGH 이상 차단"
tfsec --minimum-severity HIGH infra-rbac/

echo "[완료] 모든 검사 통과"
