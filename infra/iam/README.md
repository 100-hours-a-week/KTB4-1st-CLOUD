# IAM 사용자와 권한

인프라 담당자와 개발팀 조회 계정을 서비스 버전과 별도로 관리한다.
실행 폴더는 `infra/iam`, S3 state는 `bakkucca-terraform-state/iam/terraform.tfstate`다.

| 파일 | 관리 대상 |
|---|---|
| `main.tf` | backend, provider와 공통 데이터 조회 |
| `iam-users.tf` | 관리자/개발자 iam user, 그룹 가입과 개인별 정책 연결 |
| `infra-admin-group.tf` | 관리자 그룹과 v2에 추가된 관리형 정책 연결 |
| `infra-admin-policy.tf` | 관리자 정책(기존 정책은 인라인, v2에 추가된 정책은 관리형) |
| `observability-viewers-group.tf` | 공통 조회 그룹과 AWS 관리형 정책 2개 연결 |
| `backend-ssm-policy.tf` | dev, prod BE SSM 셸 접속 공통 정책 |
| `mfa-policy.tf` | 관리자 그룹, martin(개발팀 iam user) 공통 MFA 관리와 미인증 요청 차단 |

## 권한

인프라 담당자 두 계정에 동일한 권한을 부여함

| 대상 | 허용 범위 |
|---|---|
| EC2, S3, CloudFront, CloudWatch, Logs, SNS | v1 컨테이너 로그 그룹 삭제·보관 기간 변경 금지 |
| ECS, Auto Scaling, ALB, CodeDeploy, ElastiCache, RDS | 서울 리전 운영 권한 |
| ACM | 서울과 버지니아 인증서 관리(버지니아 리전 필수로 요구함) |
| Route 53 | DNS 조회와 `bakkucca.com` Hosted Zone 레코드 변경 |
| SSM Parameter Store | `/bakkucca-v2-*/*` 설정과 비밀값 관리 |
| Secrets Manager | `bakkucca-v2-*`와 공통 `bakkucca/ghcr` 관리 |
| IAM | 역할 조회와 v2 EC2·ECS 태스크·CodeDeploy 역할 전달. 역할 종류에 맞는 AWS 서비스로만 전달 가능 |
| 서비스 연결 역할 | ECS, Auto Scaling, ALB, ElastiCache, RDS의 최초 서비스 연결 역할 생성 |

- MFA 인증이 없는 API 요청은 차단
- IAM 사용자, 역할, 정책의 생성 및 권한 변경은 차단
  - 해당 리소스를 생성, 변경하는 전체 v2 Terraform apply는 `bootstrap-admin`으로 실행
- `*-deploy` 역할과 v1 역할, 다른 서비스로의 역할 전달은 허용하지 않음
- 계정과 그룹에 `prevent_destroy`를 설정

## 실행

```sh
cd infra/iam
terraform init
terraform plan -out=iam.tfplan
terraform apply iam.tfplan
```

- IAM 권한을 변경할 수 있는 `bootstrap-admin` 자격 증명으로 실행
- S3 backend는 `use_lockfile = true`로 같은 state의 동시 apply를 방지함

## IAM 사용자 목록

```
IAM 사용자
├── tobby               # 인프라 관리자
├── janna               # 인프라 관리자
├── bakkucca-log-viewer # 공용 로그/메트릭 조회
└── martin              # 로그/메트릭 조회, dev/prod BE SSM 접속
```