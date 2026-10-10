# 로컬 재현: `scripts/run-build-verify.sh`

CI에 올리기 전에 `app/Dockerfile`의 빌드, 헬스체크, 비-root 실행을 로컬에서 한 번에 확인한다.

## 사전 조건

- Docker Desktop 실행 중
- 레포 루트(`whitehat-supply-chain-security/`)에서 실행
- 호스트 3000번 포트가 비어 있어야 함(사용 중이면 스크립트가 시작 단계에서 안내 후 종료)
- `curl` 설치(`lsof`가 없으면 포트 사전 점검만 건너뛴다)

## 실행

```bash
bash scripts/run-build-verify.sh
```

3000번 포트가 사용 중이면 호스트 포트를 바꿔서 실행한다. 컨테이너 포트는 3000으로 고정이다.

```bash
HOST_PORT=3001 bash scripts/run-build-verify.sh
```

## 단계와 성공 기준

| 단계 | 하는 일 | 성공 기준 |
| --- | --- | --- |
| 사전 점검 | Docker 연결, `app/Dockerfile` 존재, `curl`, 호스트 포트 확인 | 오류 메시지 없이 다음 단계 진행 |
| 1/3 | 이미지 빌드(`whitehat-demo:local-verify`) | 빌드 성공 |
| 2/3 | 컨테이너 기동 후 `/health`를 최대 15초 대기 | 응답 수신(예: `{"status":"ok"}`) |
| 3/3 | 컨테이너 안에서 `whoami` 실행 | 실행 계정이 `root`가 아님(예: `node`) |

전체 통과 시 종료 코드 `0`과 `전체 통과` 메시지가 출력된다. 실패하면 종료 코드 `1`과 원인 메시지가 출력된다. 성공·실패와 관계없이 종료 시 컨테이너는 자동으로 삭제된다.
