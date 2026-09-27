#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in checkov tfsec; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "오류: $tool 명령어가 필요합니다." >&2
    exit 127
  fi
done

echo "[Checkov] Dockerfile 검사"
checkov -d . --framework dockerfile --compact --quiet

echo "[Checkov] Kubernetes YAML 검사"
checkov -d . --framework kubernetes --compact --quiet

echo "[Checkov] GitHub Actions 검사"
checkov -d . --framework github_actions --compact --quiet

echo "[tfsec] infra-rbac/ 검사: HIGH 이상 차단"
tfsec --minimum-severity HIGH infra-rbac/
