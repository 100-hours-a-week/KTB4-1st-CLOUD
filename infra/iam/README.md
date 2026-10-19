# 인프라 담당자 IAM

`tobby`, `janna`와 `Infra-Admin` 그룹을 서비스 버전과 별도로 관리한다.
실행 폴더는 `infra/iam`, S3 state는 `bakkucca-terraform-state/iam/terraform.tfstate`다.

| 파일 | 관리 대상 |
|---|---|
| `users.tf` | 기존 계정, 그룹, MFA와 t4g 제한 및 v1 공통 운영 권한 |
| `v2-policy.tf` | v2 운영 정책과 그룹 연결 |
| `imports.tf` | v1에서 인계받는 기존 리소스 |
| `main.tf` | 독립 backend, AWS 계정 제한과 공통 태그 |

## 권한

두 계정에 동일한 권한을 부여한다. 기존 비밀번호, 액세스 키, MFA와 그룹 이름은 유지한다.

| 대상 | 허용 범위 |
|---|---|
| 기존 EC2, S3, CloudFront, CloudWatch, Logs, SNS | 기존 운영 권한 유지. v1 컨테이너 로그 그룹 삭제·보관 기간 변경 금지 |
| ECS, Auto Scaling, ALB, CodeDeploy, ElastiCache | 서울 리전 운영 권한. 이 서비스들은 리소스 이름별로 제한하지 않음 |
| ACM | 서울과 버지니아 인증서 관리 |
| Route 53 | DNS 조회와 `bakkucca.com` Hosted Zone 레코드 변경 |
| SSM Parameter Store | `/bakkucca-v2-*/*` 설정과 비밀값 관리 |
| SSM 접속과 명령 실행 | `Project=bakkucca`, `InfraVersion=v2` 태그가 모두 있는 서울 EC2. 세션 재연결·종료는 본인 세션만 허용 |
| Secrets Manager | `bakkucca-v2-*`와 공통 `bakkucca/ghcr` 관리 |
| IAM | 역할 조회와 v2 EC2·ECS 태스크·CodeDeploy 역할 전달. 역할 종류에 맞는 AWS 서비스로만 전달 가능 |
| 서비스 연결 역할 | ECS, Auto Scaling, ALB, ElastiCache의 최초 서비스 연결 역할 생성 |

- MFA 인증이 없는 API 요청은 기존 정책대로 차단한다. CLI에서는 MFA로 발급한 STS 임시 자격 증명을 사용한다.
- IAM 사용자·역할·정책의 생성 및 권한 변경은 기존처럼 차단한다. 해당 리소스를 생성·변경하는 전체 v2 Terraform apply는 `bootstrap-admin`으로 실행한다.
- `*-deploy` 역할과 v1 역할, 다른 서비스로의 역할 전달은 허용하지 않는다.
- 계정과 그룹에 `prevent_destroy`를 설정한다.

## 실행

```sh
cd infra/iam
terraform init
terraform plan -out=iam.tfplan
terraform apply iam.tfplan
```

IAM 권한을 변경할 수 있는 `bootstrap-admin` 자격 증명으로 실행한다.
S3 backend는 `use_lockfile = true`로 같은 state의 동시 apply를 방지한다.

## v1에서 이전

계정을 재생성하지 않고 [Terraform의 removed/import 방식](https://developer.hashicorp.com/terraform/language/state/refactor)으로 관리 state만 이전한다.

1. v1 state를 비공개 파일로 백업하고, 이전 중 v1과 IAM의 다른 apply를 중단한다.
2. `infra/v1/iam-migration.tf`의 `removed`를 적용한다. plan에서 여섯 리소스가 `forget`이고 생성·변경·삭제가 없는지 확인한다.
3. 이 폴더에서 plan을 확인한 뒤 apply한다. `imports.tf`가 계정 2개, 그룹 1개, 사용자별 그룹 소속 2개, 기존 인라인 정책 1개를 인계한다.
4. v1 state에서 여섯 주소가 제거되고 IAM state에만 있는지 확인한다. UserId, GroupId, 액세스 키와 MFA 등록을 이전 전과 대조한다.

v1의 EC2 역할, 업로드용 계정과 로그 조회용 계정은 각 서비스의 기존 state에서 관리한다.
