# C-3 시나리오 — 휴면 후 외부 아웃바운드 연결

## 구성
- `receiver/` — beacon을 받아줄 내부 엔드포인트 (nginx, `/beacon` 경로 200 응답)
- `beacon/` — 5분 휴면 후 receiver로 curl 요청을 보내는 재현용 이미지
- `receiver-deployment.yaml` — receiver 배포 (Deployment + Service)
- `beacon-pod.yaml` — 재현 파드 배포 (1회성 Pod)

## 1. 이미지 빌드 및 ECR push

```bash
# receiver
cd receiver
docker build -t c3-beacon-receiver:v1 .
docker tag c3-beacon-receiver:v1 <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon-receiver:v1

# beacon (재현용)
cd ../beacon
docker build -t c3-beacon:v1 .
docker tag c3-beacon:v1 <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon:v1

# 두 이미지 각각 새 ECR 저장소 필요 (없으면 먼저 생성)
aws ecr create-repository --repository-name c3-beacon-receiver --region ap-northeast-2
aws ecr create-repository --repository-name c3-beacon --region ap-northeast-2

aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com

docker push <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon-receiver:v1
docker push <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/c3-beacon:v1
```

> Kyverno의 `disallow-latest-tag`, `disallow-root-user` 정책 때문에 `:latest` 태그와 root 실행은 배포 단계에서 거부됩니다.
> receiver는 `nginxinc/nginx-unprivileged` 이미지(비-root 기본), beacon은 Dockerfile에서 `USER runner`로 비-root 실행하도록 이미 구성되어 있습니다.

## 2. receiver 먼저 배포 (9/23까지, 준비 단계)

```bash
kubectl apply -f receiver-deployment.yaml
kubectl get pods -n ns-김서연 -l app=c3-beacon-receiver
```

정상 기동 확인:

```bash
kubectl run -it --rm debug --image=curlimages/curl -n ns-김서연 --restart=Never -- \
  curl -sS http://c3-beacon-receiver.ns-김서연.svc.cluster.local:8080/beacon
# "beacon received" 응답 오면 정상
```

## 3. 9/24 당일 — 재현 파드 실행

**실행 전 팀 채널에 "지금부터 시나리오 C-3 실행합니다" 공지 필수**

```bash
kubectl apply -f beacon-pod.yaml
kubectl logs -f c3-dormant-beacon -n ns-김서연
```

로그에 `beacon sent` 찍히는 시각과, Falco/Slack 알림이 뜨는 시각을 각각 기록해서
소요 시간(탐지 지연) 계산.

## 4. 정리

```bash
kubectl delete pod c3-dormant-beacon -n ns-김서연
```

receiver는 시나리오 재실행 대비해서 계속 띄워둬도 됨.
