# 사전 구성: 스크립트가 없는 단계들

`scripts/`의 스크립트(02, 04, 05, 07)는 아래 네 가지가 **이미 되어 있다고 가정**한다. 이 단계들은 스크립트로 만들지 않았고, 팀이 실제로 했던 방법을 이 문서에 기록한다. 스크립트 번호로는 01(클러스터), 03(Kyverno), 06(CI용 AWS 구성)에 해당하고, 2번(EBS CSI)은 번호가 없던 단계이다.

> **이 문서의 한계**: 명령은 팀 보고서(8/22, 9/3, 9/12)와 운영 기록에서 옮긴 것이고 지금 다시 실행한 것이 아니다. 같은 이름의 리소스가 이미 있으면 실패할 수 있다. 각 단계의 "현재 상태"는 10/10에 읽기 전용 명령으로 확인한 값이다.

---

## 1. EKS 클러스터와 접근 권한 (스크립트 번호 01에 해당)

**클러스터**는 `eksctl`(CloudFormation)로 만들었다.

```bash
eksctl create cluster \
  --name whitehat-eks \
  --region ap-northeast-2 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 3 \
  --managed
```

- 노드는 `t3.medium` 2대(실습 목적의 최소 구성), 생성에 약 15~20분이 걸린다. 버전은 지정하지 않아 `eksctl`의 기본값이다.
- **`eksctl`로 만든 인프라라 Terraform 코드가 없다.** 그래서 IaC 스캔의 대상은 RBAC를 따로 관리하는 `infra-rbac/`뿐이다.
- `eksctl create cluster`는 **OIDC 공급자를 자동으로 연결하지 않는다**(생성 로그에 `OIDC is disabled` 경고). 이 연결은 `02-setup-irsa.sh`의 1단계가 한다.
- **삭제**: `eksctl delete cluster --name whitehat-eks --region ap-northeast-2`. 켜 두면 비용이 계속 발생한다.

**팀원 접근**(RBAC 전환)은 두 단계이다. 신규 클러스터를 만들면 `eksctl`이 IAM 사용자 일부를 Access Entry로 자동 등록한다. 그 뒤에 네임스페이스와 Role을 만들고, 팀원마다 본인 네임스페이스 범위의 권한을 연결했다.

```bash
cd infra-rbac && terraform init && terraform plan && terraform apply     # ns-<이름> 네임스페이스와 Role

aws eks associate-access-policy \
  --cluster-name whitehat-eks --region ap-northeast-2 \
  --principal-arn arn:aws:iam::<AWS_ACCOUNT_ID>:user/<이름> \
  --access-scope type=namespace,namespaces=ns-<이름> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy
```

- `aws eks create-access-entry`는 이미 등록되어 `ResourceInUseException`이 나므로 건너뛰고 `associate-access-policy`만 실행한다.
- 일반 팀원이 `aws eks update-kubeconfig`를 하려면 `eks:DescribeCluster`, `eks:ListClusters`를 허용하는 정책이 따로 필요하다(`PowerUserAccess`는 EKS 조회 권한 일부를 제외한다).
- ClusterRoleBinding으로 권한을 주면 Access Entry에서는 **전체 ARN을 사용자 이름으로** 써야 매칭된다.

**현재 상태**(10/10 확인): 클러스터는 **2026-08-28 14:14(KST)** 에 만들어졌고 Kubernetes 1.34, `ACTIVE`이다. CloudFormation 스택은 `eksctl-whitehat-eks-cluster`, `eksctl-whitehat-eks-nodegroup-standard-workers`, 그리고 EBS CSI용 `eksctl-whitehat-eks-addon-iamserviceaccount-kube-system-ebs-csi-controller-sa`이다.

**확인** (읽기 전용)

```bash
aws eks describe-cluster --name whitehat-eks --region ap-northeast-2 --query 'cluster.{version:version,createdAt:createdAt,status:status}' --output table
aws cloudformation list-stacks --region ap-northeast-2 --query "StackSummaries[?contains(StackName,'whitehat-eks') && StackStatus!='DELETE_COMPLETE'].[StackName,StackStatus]" --output table
```

---

## 2. EBS CSI 드라이버와 기본 StorageClass (번호 없는 단계)

EKS 1.34 클러스터에는 **EBS CSI 드라이버가 기본으로 없고**, 기본 StorageClass도 없다. 이 둘이 없으면 Falcosidekick UI의 Redis PVC가 `Pending`에 머문다. 처음에는 권한 문제로 오진했던 사례이다.

```bash
# ① 드라이버용 IAM 역할(IRSA)
eksctl create iamserviceaccount --name ebs-csi-controller-sa --namespace kube-system \
  --cluster whitehat-eks --region ap-northeast-2 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve --role-only --role-name AmazonEKS_EBS_CSI_DriverRole

# ② 애드온 설치
eksctl create addon --cluster whitehat-eks --region ap-northeast-2 \
  --name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::<AWS_ACCOUNT_ID>:role/AmazonEKS_EBS_CSI_DriverRole --force
```

```yaml
# ③ 암호화한 gp3를 기본 StorageClass로
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

- `kubernetes.io/aws-ebs`(내장 프로비저너)는 제거되어, 기본값으로 지정해도 CSI 드라이버가 없으면 동작하지 않는다.
- **이미 실패한 PVC는 기본 StorageClass가 생겨도 자동으로 다시 시도하지 않는다.** PVC를 지우고 다시 만들어야 하며, 사용 중인 파드가 있으면 `Terminating`에서 멈출 수 있다.
- 저장소 루트의 `eks-addon-policy.json`, `trust-policy.json`이 이 단계와 관련 있는지는 [확정 전: 확인하지 못했다].

**확인** (읽기 전용)

```bash
kubectl get storageclass
kubectl get csidrivers
eksctl get addon --cluster whitehat-eks --region ap-northeast-2
```

**현재 상태**(10/10 확인): `ebs.csi.aws.com` CSI 드라이버가 있고, 기본 StorageClass는 `gp3`(`ebs.csi.aws.com`, 볼륨 확장 허용, `WaitForFirstConsumer`)이다. 예전 `gp2`(`kubernetes.io/aws-ebs`)는 남아 있지만 기본이 아니다. `aws-ebs-csi-driver` 애드온은 **v1.66.0-eksbuild.1, `ACTIVE`, 문제 0건**이고 IAM 역할은 `AmazonEKS_EBS_CSI_DriverRole`이다. 그 밖에 `coredns`, `kube-proxy`, `vpc-cni`, `metrics-server` 애드온도 `ACTIVE`이다. 클러스터의 CloudFormation 스택 목록(위 1번)에는 이 단계의 IAM 서비스어카운트 스택이 보인다.

---

## 3. Kyverno (스크립트 번호 03에 해당)

Helm으로 설치했다.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
```

`falco-exception.yaml`(PolicyException)을 쓰려면 **정책 예외 기능을 켜야** 하고, 예외를 `falco` 네임스페이스에서만 인정하도록 범위를 제한했다.

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set features.policyExceptions.enabled=true \
  --set features.policyExceptions.namespace=falco
```

- Kyverno는 PolicyException 기능을 **기본으로 꺼 둔 채** 배포한다(예외는 정책을 우회하는 수단이기 때문). 켜지 않으면 `would not be processed until it is enabled` 경고가 나온다.
- `verify-image-signature`는 `ImageValidatingPolicy`(`policies.kyverno.io`)를 쓰고, `ClusterPolicy`(`kyverno.io`)와 **API 그룹이 다르다.** `kubectl get clusterpolicy`에는 나오지 않으므로 `kubectl get imagevalidatingpolicy`로 따로 본다. 정책 관리용 ClusterRole에는 두 API 그룹을 모두 넣어야 한다.
- 클러스터 범위 정책을 조회·적용하려면 권한이 필요하다(일반 팀원 권한으로는 `05-apply-kyverno-policies.sh`가 첫 단계에서 멈춘다).

**현재 상태**(10/10 확인): **Kyverno v1.19.0**(차트 `kyverno-3.9.0`), 리비전 2(2026-09-11 20:00 KST에 업그레이드), 사용자 지정 값은 `features.policyExceptions.enabled: true`와 `namespace: falco`이다. 기록한 명령과 일치한다.

**확인** (읽기 전용)

```bash
helm list -n kyverno
helm get values kyverno -n kyverno
kubectl get crd -o name | grep kyverno
```

---

## 4. CI용 AWS 구성 (스크립트 번호 06에 해당)

GitHub Actions가 액세스 키 없이 AWS에 접근하도록 **세 가지**를 만들었다.

**① ECR 저장소**

```bash
aws ecr create-repository --repository-name whs4-demo-app --region ap-northeast-2
```

**② IAM에 GitHub OIDC 공급자 등록**: 발급자 `https://token.actions.githubusercontent.com`, 대상(audience) `sts.amazonaws.com`.

**③ IAM 역할 `GitHubActionsECRRole`**: `sts:AssumeRoleWithWebIdentity`를 허용하는 신뢰 정책으로 만들고 `AmazonEC2ContainerRegistryPowerUser` 관리형 정책을 붙인다.

처음에 기록한 신뢰 조건은 이랬다.

```json
"Condition": {
  "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
  "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<GITHUB_OWNER>/<GITHUB_REPOSITORY>:*" }
}
```

`sub`의 끝이 `:*`이면 **그 저장소의 모든 브랜치와 PR 실행**이 이 역할을 맡을 수 있다. 이 조건은 이후에 **`main` 한 값의 정확 일치**(`StringEquals`)로 좁혔다. 현재 형태와 이유는 README의 CI·AWS 항목을 본다.

**워크플로**는 `aws-actions/configure-aws-credentials@v4`의 `role-to-assume`으로 이 역할을 맡고, `id-token: write`는 ECR push와 서명 Job에만 부여한다.

**현재 상태**(10/10 확인): ECR 저장소 `whs4-demo-app`은 **2026-08-31 23:50(KST)** 에 만들었고 태그 가변(`MUTABLE`), push 시 스캔(`scanOnPush`)이 켜져 있다. 역할은 **2026-08-22 15:04(KST)** 에 만들었고 붙은 정책은 `AmazonEC2ContainerRegistryPowerUser` 하나이다.

**확인** (읽기 전용)

```bash
aws ecr describe-repositories --repository-names whs4-demo-app --region ap-northeast-2 --query 'repositories[0].{created:createdAt,mutability:imageTagMutability,scanOnPush:imageScanningConfiguration.scanOnPush}' --output table
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text | tr '\t' '\n' | sed -E 's/[0-9]{12}/<AWS_ACCOUNT_ID>/g'
aws iam get-role --role-name GitHubActionsECRRole --query 'Role.CreateDate' --output text
aws iam list-attached-role-policies --role-name GitHubActionsECRRole --query 'AttachedPolicies[].PolicyName' --output text
```

---

## 비용과 정리

네 단계 모두 **비용이 발생**한다(EKS 컨트롤 플레인과 노드, EBS 볼륨, ECR 저장). 정리 순서는 README의 "정리·삭제"를 따른다.
