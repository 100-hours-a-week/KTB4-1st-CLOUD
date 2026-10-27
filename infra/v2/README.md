# v2 인프라

- 운영·개발: 두 AZ의 ECS on EC2, 서비스별 ASG·Capacity Provider, ALB·CloudFront
- 운영 데이터: RDS MySQL과 Serverless Valkey, 별도 Kafka EC2
- 스테이징: prod와 같은 앱·네트워크·RDS·Valkey·Kafka·배포 구성. AWS 자원은 시험 시 재구축
- 운영 DNS: 수동 관리. 서비스 DNS 전환과 CloudFront 원본 변경은 별도 작업

## 환경과 실행 위치

| 환경 | CLOUD 루트 기준 실행 폴더 | state key | 관리 대상 |
|---|---|---|---|
| 운영 | `infra/v2/environments/prod` | `v2/prod/terraform.tfstate` | 앱·RDS·Valkey·Kafka |
| 개발 | `infra/v2/environments/dev` | `v2/dev/terraform.tfstate` | 앱·MySQL/Valkey/Kafka 데이터 EC2 |
| 스테이징 | `infra/v2/environments/staging` | `v2/staging/terraform.tfstate` | 운영과 같은 앱·RDS·Valkey·Kafka, 시험용 v1 연결 |

- `infra/v2` 루트는 실행 폴더가 아님
- 운영 VPC `10.20.0.0/16`, 개발 `10.40.0.0/16`, 스테이징 `10.30.0.0/16`
- staging은 prod와 같은 platform·RDS·Valkey 모듈과 서비스 용량 기본값 사용
- staging AWS에는 DB 네트워크·RDS만 유지. 재구축 전 [staging 준비](environments/staging/README.md) 확인
- DB 복제·데이터 이관·DB 롤백과 복제 EC2 설정은 DB 담당자 관리

## 파일 구성

| 위치 | 역할 |
|---|---|
| `environments/*/main.tf` | state·provider·환경별 모듈 입력 |
| `environments/prod/github-deploy.tf` | 운영 GitHub OIDC 배포 역할 |
| `environments/dev/data.tf` | 개발 데이터 EC2·볼륨·컨테이너 |
| `environments/{prod,staging}/rds.tf` | RDS 사양과 접속 설정 |
| `environments/{prod,staging}/migration.tf` | v1 피어링·RDS 통신 경로와 SG |
| `environments/staging/moved.tf` | 보존된 DB 네트워크를 platform 주소로 이전 |
| `modules/platform` | 앱 네트워크·ECS·ASG·ALB·CloudFront·IAM·SSM·CodeDeploy·Kafka |
| `modules/rds` | RDS·subnet group·SG |
| `modules/serverless-valkey` | 운영 Serverless Valkey |
| `modules/migration-network` | DB 네트워크 분리용 모듈, staging 복원 시 platform으로 인계 |

## DNS와 요청 경로

| 구분 | 관리 방식 |
|---|---|
| 운영 서비스 도메인 | 수동 DNS 설정 유지. prod는 서비스 A/AAAA를 생성하지 않음 |
| `publish_service_dns` | 개발 등 비운영 환경의 서비스 A/AAAA 생성 제어. prod에는 적용되지 않음 |
| `origin.<도메인>`·인증서 검증 레코드 | platform 모듈에서 관리 |
| staging 서비스 DNS·CloudFront | 서비스 DNS는 기본 미등록. 기존 CloudFront는 재구축 전 state 소유권 확인 |
| 기존 v1 DNS 코드 | 루트 도메인 A를 v1 EIP로 정의. 적용 전 실제 DNS와 대조 |

- DNS: 도메인이 연결되는 CloudFront 또는 서버 결정
- CloudFront 원본: CloudFront가 요청을 전달할 ALB·EC2·S3 결정
- `publish_service_dns=false`는 CloudFront 원본의 수동 변경을 보호하지 않음
- 적용 전 plan에서 DNS·CloudFront 변경과 실제 수동 설정을 대조

| 요청 | v2 코드의 전달 경로 |
|---|---|
| API·페이지 | CloudFront → 공용 ALB → BE·FE |
| FE 정적 파일 | CloudFront → FE 정적 S3 |
| `/images/*` | CloudFront 서명 검증 → 업로드 S3 |
| FE 서버의 BE 호출 | `https://origin.<도메인>/api` → ALB → BE |
| BE의 AI 호출 | 내부 ALB HTTP 80 → AI 8000 |

- ALB에서 `/api` 접두사 제거
- 동적 요청의 캐시 비활성화, 인증 헤더·쿠키·쿼리 전달
- 운영 DNS의 실제 대상은 수동 설정과 대조

## Terraform 실행

- 준비: Terraform `>= 1.16, < 2.0`, AWS 인증, state 버킷·대상 인프라 권한
- 실행 위치: 작업 PC의 CLOUD 저장소 루트
- 순서: init → validate → plan 검토 → 저장된 plan 적용 → 출력·서비스 확인
- plan 검토: 변경 환경, DNS·CloudFront, RDS·볼륨 삭제/교체, 서비스 영향
- staging 적용: DB 담당자와 변경 범위를 확인한 뒤 별도 실행

<details>
<summary>운영 실행 명령</summary>

```bash
terraform -chdir=infra/v2/environments/prod init
terraform -chdir=infra/v2/environments/prod validate
terraform -chdir=infra/v2/environments/prod plan -out=tfplan
# 변경 내용을 검토한 뒤 실행
terraform -chdir=infra/v2/environments/prod apply tfplan
terraform -chdir=infra/v2/environments/prod output services
terraform -chdir=infra/v2/environments/prod output cloudfront
```

- 개발은 실행 폴더를 `infra/v2/environments/dev`로 지정
- 기존 state key 유지, 다른 환경의 plan 재사용 금지
- staging의 `v1_network`는 DB 시험 EC2의 VPC·route table·SG와 일치시킴

</details>

## 설정과 서비스 배포

| 항목 | 관리 위치·동작 |
|---|---|
| 최초 이미지 | 환경 `main.tf`의 초기 이미지 입력 |
| 이후 이미지 | 서비스 CD가 digest 확정 → 태스크 정의 등록 → CodeDeploy 배포 |
| 컨테이너 설정 | `modules/platform/*-task-definition.json.tftpl` |
| 런타임 환경변수 | `/bakkucca-v2-<환경>/<서비스>/<키>`의 SSM 파라미터 |
| RDS 비밀번호 | Secrets Manager에서 태스크에 직접 주입 |
| FE 빌드 환경변수 | GitHub 빌드 설정. 변경 후 이미지 재빌드 |
| 기존 설정 편집 | [SSM 편집 도구](../../scripts/ssm-env.README.md) |

- Terraform은 설정 이름·조회 권한·인프라에서 결정되는 주소를 관리
- 일반 설정은 `String`, 비밀값은 `SecureString`으로 수동 관리
- SSM·Secret 변경은 새 태스크 배포 후 반영
- 최초 기동에는 세 서비스 이미지·필수 SSM·GHCR Secret `bakkucca/ghcr` 준비
- DB 주소와 계정 출력: `rds_mysql_endpoint`, `rds_mysql_port`, master secret 참조

| 환경 | 워크플로 위치 | GitHub Environment | 배포 입력 |
|---|---|---|---|
| 개발 | 각 서비스 저장소 | `dev` | dev push 또는 수동 digest |
| 운영 | 각 서비스 저장소 | `prod` | 정식 `vMAJOR.MINOR.PATCH` 태그 또는 수동 version |
| 스테이징 | CLOUD의 서비스별 staging workflow | `staging` | 정식 릴리즈 version, 앱·배포 역할 재구축 후 실행 |

<details>
<summary>배포 설정과 동작</summary>

- 역할 ARN: 해당 환경의 `terraform output github_deploy_role_arns`
- 서비스 저장소 Variables: `AWS_ROLE_ARN`
- FE Variables: `FE_STATIC_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID` (`terraform output cloudfront`)
- FE 빌드 Secret: 개발 `FE_ENV_DEV`, 운영 `FE_ENV`
- 운영 릴리즈 태그의 커밋은 서비스 main에 포함
- 운영 이미지 태그: BE `v1.2.3`, FE·AI `1.2.3`
- FE 정적 파일 업로드 → 태스크 등록 → 헬스 체크 → CodeDeploy 트래픽 전환
- 배포 방식: `CodeDeployDefault.ECSAllAtOnce`
- 구버전 태스크 보존: 개발 1분, 운영 10분
- 실패 시 이전 정상 리비전으로 롤백, 다음 배포는 이전 태스크 세트 정리 후 실행

</details>

## 데이터·파일과 기동 확인

| 항목 | 구성·확인 |
|---|---|
| 운영·staging DB | MySQL 8.4 Multi-AZ, gp3 100GiB, 최대 500GiB, 백업 7일, 삭제 방지 |
| 운영 캐시 | Serverless Valkey, TLS·사용자 인증 |
| 개발 데이터 | EC2에서 MySQL·Valkey·Kafka 실행 |
| 운영 업로드 버킷 | 기존 `bakkucca-uploads`, 버킷 자체는 v1 state에서 관리 |
| FE 정적 파일 | `.next/static/` → `_next/static/`, `public/` 내용 → 버킷 루트 |
| 이미지 조회 | CloudFront signed URL, 만료·변조 시 403 |
| 앱 확인 | ECS 태스크 수·ALB healthy·로그인·WebSocket·정적 파일 |
| 배포 확인 | CodeDeploy 성공·롤백과 ASG 용량 복귀 |

<details>
<summary>데이터 설정과 컨테이너 사양</summary>

- 운영 ASG: 서비스별 평시 2대·배포 최대 4대, 인스턴스당 태스크 1개
- 개발 ASG: 서비스별 평시 1대·배포 최대 2대
- 앱: ARM64, bridge 네트워크, 대상 그룹 유형 `instance`
- 운영 앱: 서비스별 `t4g.small`, 컨테이너 메모리 상한 1536MiB
- 개발 앱: BE·FE는 `t4g.micro`, AI는 `t4g.small`. 컨테이너 메모리 상한은 BE 640MiB·FE 512MiB·AI 1536MiB
- 사양은 `service_compute`로 설정하며 개발 데이터 EC2의 사양은 별도 관리
- 개발 BE의 SSM `JAVA_TOOL_OPTIONS`는 `-Xms128m -Xmx256m -XX:MaxMetaspaceSize=192m` 사용. 힙 이외의 JVM 메모리도 컨테이너 상한에 포함
- 개발 FE의 SSM `NODE_OPTIONS`는 `--max-old-space-size=256` 사용. V8 힙 이외의 Node.js 메모리도 컨테이너 상한에 포함
- Launch Template 적용만으로 기존 EC2가 교체되지는 않음. 새 태스크 정의 등록 후 서비스 배포로 신규 용량·ALB 상태를 확인하고 기존 EC2를 드레이닝·교체해야 사양 축소 완료
- readiness: BE `/actuator/health/readiness`, FE `/api/health/readiness`, AI `/health/readiness`
- 운영 Valkey 암호: SSM 값 변경 → `password_version` 증가·apply → BE 재배포
- 개발 데이터 EC2: SSM Session Manager, `/opt/bakkucca-data/compose.json`, systemd `bakkucca-data`
- 개발 데이터 EC2 교체 전 볼륨 보존·백업 확인, 새 접속 주소 반영 후 BE 재배포
- 기존 MySQL 비밀번호는 초기화 환경변수만 변경해도 바뀌지 않음
- FE 이전 JS·CSS는 롤백 기간까지 보존
- CloudFront 공개키·개인키는 BE SSM에서 관리하며 개인키를 Git에 저장하지 않음

</details>
