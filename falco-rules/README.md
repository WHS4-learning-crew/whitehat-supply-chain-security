# falco-rules

Falco 커스텀 룰(C-1~C-4)과 설치 방법입니다.

## 구성

- `values.yaml`: Falco Helm 차트 values. `customRules`에 C-1~C-4 룰과 오탐 예외 처리가 들어 있습니다.
- `../scripts/04-install-falco.sh`: Helm 저장소 등록, 설치/업그레이드, Pod 기동 대기, 룰 로드 검증까지 실행합니다.

## 사용 방법

```bash
export DISCORD_WEBHOOK_URL="<본인의 Discord Webhook URL>"
./scripts/04-install-falco.sh
```

웹훅 URL은 파일에 넣지 않고 환경변수로만 주입합니다. 저장소에 커밋하지 않습니다.

### 설치 권한 없이 확인하기 (렌더링만)

클러스터 설치 권한이 없는 팀원은 아래처럼 렌더링까지만 확인할 수 있습니다. `helm template`은 클러스터에 접속하지 않으므로 아무것도 적용되지 않습니다.

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm template falco falcosecurity/falco --version 9.2.0 -n falco \
  -f falco-rules/values.yaml \
  --set falcosidekick.config.discord.webhookurl="https://example.invalid/dummy" \
  > /tmp/falco-rendered.yaml
```

- 실제 Webhook URL 대신 더미 값을 넣으므로 비밀값이 필요 없습니다.
- 확인되는 범위는 차트 렌더링(values.yaml 구조)까지입니다. Falco 룰 조건식의 문법 오류는 실제 Falco가 룰을 로드할 때만 드러납니다.

## 한계

- Discord 웹훅 URL을 `helm --set`으로 주입하면 `falco` 네임스페이스의 Helm 릴리스 Secret(`sh.helm.release.v1.falco.*`)에 값이 남습니다. 릴리스 이력(리비전)에도 남으므로 해당 네임스페이스의 Secret 조회 권한을 제한해야 하며, 노출이 의심되면 웹훅을 재발급합니다.
- C-3 룰은 priority가 NOTICE라 Discord(`minimumpriority: warning`)로는 전송되지 않고 Falco 로그에서 확인합니다. 연결 1건당 이벤트가 여러 건(DNS 조회, 대상 포트 연결) 기록되므로, Discord로 받으려면 WARNING으로 올리되 알림이 중복될 수 있습니다.
- 스크립트의 `--create-namespace`로 네임스페이스가 없는 상태에서 최초 설치하는 경로는 검증하지 않았습니다.
