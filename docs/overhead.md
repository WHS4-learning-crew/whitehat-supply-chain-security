# CI 오버헤드

- 측정 조건: `main` 브랜치에서 `workflow_dispatch`로 같은 날 5회 연속 실행(`ubuntu-latest`). 7개 Job이 모두 실행된 경우의 값이다.
- **기준은 Job 소요 시간의 합계이며, Job 사이의 스케줄링 대기 시간은 포함하지 않는다.**
- **콜드**는 Trivy DB 캐시가 없는 첫 실행(Run1), **웜**은 같은 날 재실행으로 캐시가 적중한 실행(Run2~5)이다. 캐시 키는 날짜 기준이다.

| Job | 콜드(Run1) | 웜 평균(Run2~5) | 5회 평균 | 5회 범위 |
| --- | --- | --- | --- | --- |
| Gitleaks Secret Scan | 4 | 5.25 | 5 | 4–6 |
| Checkov + tfsec | 51 | 48 | 48.6 | 39–55 |
| SBOM Diff and Risk Scan | 90 | 86.5 | 87.2 | 80–91 |
| Build Docker Image | 23 | 25.25 | 24.8 | 22–27 |
| Trivy Image Scan | 65 | 40 | 45 | 35–65 |
| Push Image to ECR | 33 | 32.25 | 32.4 | 30–37 |
| Cosign Keyless Sign | 14 | 13.25 | 13.4 | 12–14 |
| **Job 합계** | **280** | **250.5** | **256.4** | **241–280** |

단위는 초이다.

- Job 합계의 5회 평균은 **256.4초**(약 4분 16초), 범위는 241~280초이다.
- 콜드(280초)와 웜 평균(250.5초)의 차이는 29.5초이고, 이 중 25초가 Trivy Image Scan(65초 → 40초)이다. Trivy DB 최초 다운로드 비용으로 해석한다.
- 참고: 전체 파이프라인 시작~종료(wall-clock) 평균은 272.8초이며, Job 사이 대기 15~18초는 위 합계에서 제외했다.
- PR 실행은 Job 6·7이 빠지므로 이 합계보다 짧다(별도 측정하지 않음).
- 원본 데이터: [ci-pipeline-baseline-5runs-utc-kst.xlsx](ci-pipeline-baseline-5runs-utc-kst.xlsx)
