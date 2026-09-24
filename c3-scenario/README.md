# C-3 시나리오 — 휴면 후 외부 아웃바운드 연결

## 구성
- `receiver/` — beacon을 받아줄 내부 엔드포인트 (nginx, `/beacon` 경로 200 응답)
- `beacon/` — 5분 휴면 후 receiver로 curl 요청을 보내는 재현용 이미지
- `receiver-deployment.yaml` — receiver 배포 (Deployment + Service, readOnlyRootFilesystem 등 Checkov 대응 포함)
- `beacon-pod.yaml` — 재현 파드 배포 (1회성 Pod)
- `network-policy.yaml` — beacon/receiver용 NetworkPolicy 2개 (Checkov CKV2_K8S_6 대응, 필수 apply)

> **네임스페이스는 `ns-kimseoyeon` 입니다.**

## 0. 이미지는 이미 ECR에 있음 (재빌드 불필요)

아래 이미지가 이미 push되어 있어서, **특별히 코드를 바꾸지 않는 한 1번 단계는 생략하고 바로 2번으로 가면 됩니다.**

- `984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon-receiver:v1`
- `984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon:v1`

확인:
```bash
aws ecr list-images --repository-name c3-beacon-receiver --region ap-northeast-2
aws ecr list-images --repository-name c3-beacon --region ap-northeast-2
```

## 1. (코드를 수정했을 때만) 이미지 빌드 및 ECR push

```bash
# receiver
cd c3-scenario/receiver
docker build -t c3-beacon-receiver:v1 .
docker tag c3-beacon-receiver:v1 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon-receiver:v1

# beacon (재현용)
cd ../beacon
docker build -t c3-beacon:v1 .
docker tag c3-beacon:v1 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon:v1

# 저장소가 아직 없다면 먼저 생성
aws ecr create-repository --repository-name c3-beacon-receiver --region ap-northeast-2
aws ecr create-repository --repository-name c3-beacon --region ap-northeast-2

aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com

docker push 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon-receiver:v1
docker push 984675940604.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon:v1
```

> **`:latest` 태그는 절대 쓰지 말 것.** Kyverno `disallow-latest-tag`, `disallow-root-user` 정책 때문에
> `:latest` 태그와 root 실행은 배포 단계에서 거부됩니다. 태그는 항상 `:v1`(또는 명시적 버전)로 push.
> receiver는 `nginxinc/nginx-unprivileged` 이미지(비-root 기본), beacon은 Dockerfile에서 `USER runner`로
> 비-root 실행하도록 이미 구성되어 있습니다.

## 2. receiver + NetworkPolicy 먼저 배포 (준비 단계)

**두 파일 다 apply 해야 합니다. NetworkPolicy를 빠뜨리면 나중에 Checkov 체크가 실패합니다.**

```bash
cd c3-scenario
kubectl apply -f receiver-deployment.yaml
kubectl apply -f network-policy.yaml
kubectl get pods -n ns-kimseoyeon -l app=c3-beacon-receiver -w
```

`1/1 Running`, `RESTARTS 0`으로 뜨는지 확인 (Ctrl+C로 감시 종료).

> 만약 `CrashLoopBackOff`가 뜨면 `kubectl logs <pod> -n ns-kimseoyeon --previous`로 원인 확인.
> 과거에 `open() "/run/nginx.pid" failed (30: Read-only file system)` 에러가 있었는데,
> `receiver-deployment.yaml`에 `/run` emptyDir 마운트를 추가해서 이미 해결된 상태입니다
> (파일을 임의로 수정하지 않았다면 재발하지 않아야 정상).

정상 기동 확인 (curl 테스트):

```bash
kubectl run -it --rm debug --image=curlimages/curl -n ns-kimseoyeon --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"debug","image":"curlimages/curl","command":["curl","-sS","http://c3-beacon-receiver.ns-kimseoyeon.svc.cluster.local:8080/beacon"],"securityContext":{"runAsNonRoot":true,"runAsUser":100,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'
# "beacon received" 응답 오면 정상
```

> `--overrides` 없이 `kubectl run`만 쓰면 Kyverno `disallow-root-user` 정책에 막혀서
> `admission webhook ... denied the request` 에러가 납니다. 위 명령어 그대로 복사해서 쓸 것.

## 3. 시나리오 당일 — 재현 파드 실행

**실행 전 팀 채널에 "지금부터 시나리오 C-3 실행합니다" 공지 필수**
(Falco 탐지 담당자가 필터링 조건 — 네임스페이스 `ns-kimseoyeon`, 목적지
`c3-beacon-receiver.ns-kimseoyeon.svc.cluster.local:8080`, 파드 라벨 `app=c3-beacon` — 로
룰을 걸어두고 대기 중이므로 실행 타이밍을 맞춰야 함)

**⚠️ receiver가 Running 상태인 걸 먼저 확인한 뒤에 실행할 것.** receiver 없이 beacon만 실행하면
`curl: (6) Could not resolve host` 에러가 나고 시나리오가 무효가 됩니다.

```bash
kubectl apply -f beacon-pod.yaml
```

beacon은 5분(300초) 휴면 후 자동으로 curl을 쏘고 종료됩니다. `-f`로 실시간 로그를 보다가
너무 일찍 끊으면 로그가 미완성 상태로 남으니, 아래처럼 **완료될 때까지 기다린 뒤에** 로그를 뜨는 걸 권장:

```bash
kubectl wait --for=condition=Ready=False pod/c3-dormant-beacon -n ns-kimseoyeon --timeout=360s

kubectl logs c3-dormant-beacon -n ns-kimseoyeon > c3-beacon-log-$(date +%Y%m%d).txt
cat c3-beacon-log-$(date +%Y%m%d).txt
```

정상이면 아래 4줄이 순서대로 찍힙니다:
```
[...] pod started, entering dormant period (300s)
[...] dormant period over, sending beacon
beacon received
[...] beacon sent, exiting
```

`dormant period over, sending beacon` 줄의 타임스탬프가 Falco/Slack 알림 시각과 비교할
"연결 시도 시각"입니다. 이 값과 Falco 알림이 뜬 시각을 각각 기록해서 소요 시간(탐지 지연) 계산.

만약 로그에 `beacon received`가 없고 `Could not resolve host` 등의 에러가 있다면
receiver가 죽어있었다는 뜻이니 2번부터 다시 실행.

## 4. 정리

```bash
kubectl delete pod c3-dormant-beacon -n ns-kimseoyeon
kubectl delete -f receiver-deployment.yaml
kubectl delete -f network-policy.yaml
```

확인:
```bash
kubectl get pods -n ns-kimseoyeon
kubectl get networkpolicy -n ns-kimseoyeon
```
아무것도 안 나오면 정리 완료.

### (선택) ECR 이미지까지 정리하고 싶을 때

```bash
# v1 이미지 태그만 삭제
aws ecr batch-delete-image --repository-name c3-beacon-receiver --region ap-northeast-2 --image-ids imageTag=v1
aws ecr batch-delete-image --repository-name c3-beacon --region ap-northeast-2 --image-ids imageTag=v1

# 저장소 자체까지 삭제하려면 (다시 쓸 계획이 전혀 없을 때만)
aws ecr delete-repository --repository-name c3-beacon-receiver --region ap-northeast-2 --force
aws ecr delete-repository --repository-name c3-beacon --region ap-northeast-2 --force
```

> `--force` 옵션은 저장소 안에 이미지가 남아있어도 강제로 삭제합니다. 재실행 계획이 조금이라도
> 있다면 저장소 삭제는 하지 말고 이미지 태그만 지우거나, 그냥 두는 것을 권장합니다.
