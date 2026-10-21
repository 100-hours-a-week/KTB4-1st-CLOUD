# v2 환경별 인프라

- 구성: 두 AZ의 ECS on EC2, 서비스별 ASG와 Capacity Provider, CloudFront와 ALB
- 최초 인프라와 ECS 서비스: Terraform
- 이후 서비스 버전 배포: GitHub Actions와 CodeDeploy
- DB 데이터 이전과 운영 트래픽 전환: 별도 작업

## 1. 환경과 실행 위치

| 환경 | 실행 폴더 | state key | 도메인 | VPC CIDR |
|---|---|---|---|---|
| 개발 | `environments/dev` | `v2/dev/terraform.tfstate` | `dev.bakkucca.com` | `10.40.0.0/16` |
| 스테이징 | `environments/staging` | `v2/staging/terraform.tfstate` | `staging.bakkucca.com` | `10.30.0.0/16` |
| 운영 | `environments/prod` | `v2/prod/terraform.tfstate` | `bakkucca.com` | `10.20.0.0/16` |

| 환경 | BE 평시 / 배포 최대 | FE와 AI 각각 평시 / 배포 최대 | DB와 캐시 | Kafka |
|---|---|---|---|---|
| 개발 | 2 / 4 | 1 / 2 | 데이터 EC2의 MySQL과 Valkey | 같은 데이터 EC2 |
| 스테이징 | 2 / 4 | 2 / 4 | 별도 RDS와 Serverless Valkey | 전용 EC2 |
| 운영 | 2 / 4 | 2 / 4 | 별도 RDS와 Serverless Valkey | 기존 전용 EC2 |

- 환경 폴더에서 각각 `init`, `plan`, `apply` 실행. `infra/v2` 루트에서는 실행하지 않음
- 환경별 리소스와 state, SSM 경로 및 접근 권한 분리
- 애플리케이션 EC2는 `t4g.small`, 인스턴스당 태스크 1개
- 같은 서비스의 태스크는 서로 다른 EC2와 두 AZ에 분산
- 운영과 스테이징의 애플리케이션 EC2는 평시 총 6대, 세 서비스 동시 배포 시 최대 12대

## 2. 파일 구성

| 위치 | 역할 |
|---|---|
| `modules/platform` | 네트워크, ECS, ASG, ALB, CloudFront, IAM, SSM, CodeDeploy와 Kafka |
| `modules/rds` | 운영과 스테이징 RDS |
| `modules/serverless-valkey` | 운영과 스테이징 공유 캐시 |
| `environments/*/main.tf` | backend, provider와 환경별 모듈 입력 |
| `environments/{prod,staging}/rds.tf` | RDS 사양과 BE 연결 |
| `environments/{prod,staging}/migration.tf` | v1 피어링, DB와 캐시 및 Kafka 접근 |
| `environments/{prod,staging}/github-deploy.tf` | 서비스별 GitHub OIDC 배포 역할 |
| `environments/prod/*moved.tf` | 기존 운영 리소스의 state 주소 이전 |
| `environments/dev/data.tf` | 개발 MySQL, Valkey와 Kafka용 EC2 및 볼륨 |

## 3. 요청 경로

| 요청 | 전달 경로 |
|---|---|
| `/_next/static/*` | CloudFront → FE 정적 파일 S3 |
| `/icons/*`, `/figma/*`, `/kakao_login_large_wide.png` | CloudFront → FE 정적 파일 S3 |
| `/images/*` | CloudFront 서명 검증 → 업로드 S3 |
| `/api`, `/api/*`, `/ws`, `/ws/*`, `/auth/kakao/callback` | CloudFront → 공용 ALB → BE |
| 페이지, `/bff/*`, `/_next/image` | CloudFront → 공용 ALB → FE |
| FE 서버의 BE 호출 | `https://origin.<서비스 도메인>/api` → 공용 ALB → BE |
| BE의 AI 호출 | 내부 ALB HTTP 80 → AI 8000 |

- ALB에서 `/api` 접두사 제거
- 동적 응답 캐시 비활성화, 인증 헤더와 쿠키 및 쿼리 전달
- `/_next/static/*` 캐시 최대 1년, 나머지 FE 정적 경로 최대 5분
- 개발과 스테이징 DNS는 전체 적용 시 CloudFront A와 AAAA Alias 생성
- 운영 DNS 전환은 별도 진행. 스테이징 전환 시험에서도 자동 DNS 생성 시점 확인

| 서비스 | 컨테이너 | 호스트 포트 | ALB 헬스 체크 | 메모리 예약 / 상한 |
|---|---|---|---|---|
| BE | `backend` | 8080 | `/actuator/health/readiness` | 512 / 1536MiB |
| FE | `frontend` | 3000 | `/api/health/readiness` | 256 / 1536MiB |
| AI | `ai` | 8000 | `/health/readiness` | 512 / 1536MiB |

- ARM64, bridge 네트워크, ALB 대상 유형 `instance`
- 메모리 값은 `modules/platform/*-task-definition.json.tftpl` 기준

## 4. 최초 적용

### 준비 항목

- Terraform `>= 1.16, < 2.0`, AWS 인증과 state 버킷 접근 권한
- 서울 리전 인프라와 버지니아 리전 CloudFront 인증서 생성 권한
- IAM 역할 변경과 `iam:PassRole` 권한. 서비스 연결 역할 최초 생성 시 추가 권한 필요
- Route 53 Hosted Zone `bakkucca.com`, GHCR 인증정보 `bakkucca/ghcr`
- Kafka 공개키 `bakkucca-v1`, `bakkucca-v1-janna`
- 계정과 인프라 담당자 권한: [IAM 관리 안내](../iam/README.md)

### 이미지와 환경 입력

| 입력 | 용도 |
|---|---|
| `initial_image_digests` | 서비스별 최초 이미지 지정. 개발만 `latest` 허용 |
| 최초 이미지 기본값 | 개발은 GHCR `latest`, 운영과 스테이징은 `releases/v1.5.1.yaml`의 서비스별 digest |
| `password_version` | Serverless Valkey 비밀번호 변경 시 증가. 기본값 `1` |
| staging `v1_network` | 시험용 v1의 VPC, CIDR, route table과 SG |

- 운영과 스테이징의 기본 번들을 최신 릴리즈로 간주하지 않음. 필요한 기능과 환경별 FE 빌드 확인
- 서비스 생성 이후 버전 변경은 CD 사용, 최초 이미지 입력은 유지
- staging의 기존 `v1_network` 입력을 제거하면 복제 경로 삭제가 계획될 수 있으므로 보존
- tfvars 예시 파일 없이 필요한 입력만 해당 환경의 `terraform.tfvars`에 지정
- 빈 `initial_image_digests`는 기본 번들로 대체되며 전체 서비스 비활성화 입력이 아님

### 런타임 설정

| 구분 | 관리 방법 |
|---|---|
| SSM 이름 | `/bakkucca-v2-<환경>/<서비스>/<환경변수 이름>` |
| 일반값과 비밀값 | `String`과 `SecureString`, 환경변수별 파라미터 하나 |
| Terraform 자동 등록 | DB와 캐시 주소, Kafka, AI, FE의 BE 호출 주소, CloudFront 주소와 공개키 ID |
| 수동 등록 | JWT와 OAuth 비밀값, Redis 비밀번호, 이미지 서명키, 서비스별 일반 설정 |
| 운영 S3 버킷 이름 | BE SSM `AWS_S3_BUCKET`에 기존 `bakkucca-uploads` 등록 |
| 서비스별 필수 키 | `modules/platform/parameters.tf`의 `runtime_parameter_keys` 확인 |
| 기존 env 일괄 이전 | [9절](#9-기존-env의-ssm-일괄-등록) 사용 |

- 수동 설정과 이미지 서명키를 준비한 뒤 전체 plan 실행
- 실제 비밀값을 코드와 tfvars에 저장하지 않음
- FE의 `NEXT_PUBLIC_*`는 GitHub 빌드 설정이며 이미지 재빌드 필요
- FE와 BE의 Kakao callback은 해당 환경의 `https://<도메인>/auth/kakao/callback`으로 일치
- 로그인 완료 주소 `https://<도메인>/auth/callback`은 FE로 전달

### 적용 순서

1. 환경 입력과 수동 SSM 설정, GHCR 인증 준비
2. 기존 DB 이전 여부와 최초 BE 기동 시점 확인
3. 아래 plan에서 생성, 변경과 삭제 대상 검토
4. 검토한 plan 적용 후 DB와 캐시, 태스크 기동 확인
5. FE 이미지와 같은 빌드의 정적 파일 업로드
6. 서비스별 CD와 기능 검증

```sh
# CLOUD 저장소 루트에서 실행. prod 또는 staging은 폴더를 변경한다.
terraform -chdir=infra/v2/environments/dev init
terraform -chdir=infra/v2/environments/dev validate
terraform -chdir=infra/v2/environments/dev plan -out=tfplan
terraform -chdir=infra/v2/environments/dev apply tfplan
terraform -chdir=infra/v2/environments/dev output services
terraform -chdir=infra/v2/environments/dev output cloudfront
terraform -chdir=infra/v2/environments/dev output github_deploy_role_arns
```

- 전체 apply에 RDS뿐 아니라 최초 ECS 서비스와 DNS 생성도 포함될 수 있음
- DB dump와 복원, binlog 복제, 기존 애플리케이션 DB 전환은 Terraform이 수행하지 않음
- RDS 우선 구축: [DB 전환 리허설](../migration-staging/README.md)
- 트래픽 전환: [마이그레이션 계획](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v2-Migration), [스테이징 계획](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v2-Staging)

## 5. 저장소와 파일 설정

### DB와 캐시

| 항목 | 운영과 스테이징 | 개발 |
|---|---|---|
| DB | RDS MySQL 8.4, Multi-AZ, `db.t4g.small` | EC2의 MySQL 8.4 |
| RDS 저장소 | gp3 100GiB, 최대 500GiB, 백업 7일과 삭제 방지 | 해당 없음 |
| DB 일반값 | `DB_URL`, `DB_USERNAME`을 Terraform이 SSM에 등록 | 계정은 SSM에 수동 등록, 주소는 자동 등록 |
| DB 비밀번호 | ECS에서 RDS Secrets Manager의 `password` JSON key 직접 주입 | SSM `DB_PASSWORD` |
| 캐시 | Valkey 8 Serverless, TLS와 사용자 인증 | Valkey 8 standalone |
| 캐시 설정 | cluster nodes, username, TLS 설정 자동 등록 | host, port, TLS 설정 자동 등록 |
| 캐시 비밀번호 | SSM `SPRING_DATA_REDIS_PASSWORD` | 동일 |

- RDS 비밀번호는 SSM에 복사하지 않으며 Terraform이 값을 조회하지 않음
- `rds_mysql_endpoint`와 `rds_mysql_port` 출력은 각각 호스트와 포트
- Serverless Valkey는 전체 plan 전에 비밀번호 등록 필요. 상한은 1GB와 1,000 ECPU/초
- Valkey 비밀번호 변경: SSM 값 수정 → `password_version` 증가 후 apply → BE 재배포
- RDS 비밀번호 회전이나 SSM 값 변경 후에도 실행 중 태스크는 기존 값 사용. 새 태스크 배포 필요
- v1 Compose의 Redis 설정은 기존 `ENV_FILE` → `.env.shared` 경로 사용
- 같은 환경의 v1과 v2가 공유하는 DB와 캐시를 마이그레이션 중 유지
- Redis 클라이언트, 키 형식과 TTL, 인증 상태 호환은 애플리케이션에서 검증

### Kafka와 개발 데이터 EC2

| 환경 | 구성 | 확인할 내용 |
|---|---|---|
| 운영 | 기존 전용 Kafka EC2 유지 | 설치와 실행 설정 자동 변경 없음 |
| 스테이징 | 전용 EC2에 Kafka 자동 설치 | 기존 시험용 브로커의 메시지와 소비 위치를 자동 이전하지 않음 |
| 개발 | MySQL, Valkey와 Kafka를 데이터 EC2 한 대에서 실행 | 데이터 볼륨 보존과 컨테이너 기동 |

| 개발 컨테이너 | 메모리 상한 | 주요 설정 |
|---|---|---|
| MySQL | 640MiB | InnoDB 128MiB, 최대 연결 40 |
| Valkey | 192MiB | maxmemory 64MiB, AOF, noeviction |
| Kafka | 768MiB | 힙 128~256MiB, 보관 24시간과 파티션별 512MiB |

- 개발 데이터 EC2는 SSM Session Manager로 관리
- 실행 설정: `/opt/bakkucca-data/compose.json`, 서비스: `bakkucca-data`
- user data 변경으로 데이터 EC2가 교체될 수 있으므로 plan 확인
- 교체 전 요청과 쓰기 중지, 컨테이너 정상 종료와 볼륨 백업
- 기존 MySQL과 Valkey 데이터 및 Kafka 소비 위치 보존 여부 확인
- 새 EC2 주소가 등록된 뒤 BE 재배포
- 기존 데이터의 MySQL 비밀번호는 초기화 환경변수 변경만으로 바뀌지 않음

### FE 정적 파일과 업로드 이미지

| 항목 | 처리 |
|---|---|
| `.next/static/` | FE 정적 버킷의 `_next/static/`에 업로드 |
| `public/` 내용 | FE 정적 버킷 루트에 업로드. `/public` 접두사 사용 안 함 |
| 이전 FE 빌드 | 이전 JS와 CSS를 롤백 기간까지 보존 |
| 운영 업로드 버킷 | 기존 `bakkucca-uploads` 참조, 버킷 자체는 v1 state에서 관리 |
| 개발과 스테이징 버킷 | 환경별 생성 |
| 업로드 | 기존 S3 presigned PUT 유지 |
| 사용자 이미지 조회 | CloudFront signed URL과 OAC 사용, BE 서명 구현 필요 |
| AI 분석용 이미지 | 기존 S3 GET URL 유지 |

- 공개키: BE SSM `CLOUDFRONT_PUBLIC_KEY_PEM`, `String`
- 개인키: BE SSM `CLOUDFRONT_PRIVATE_KEY_PEM`, `SecureString`
- 기존 키가 있으면 재사용. 새 키가 필요할 때 RSA 2048 키 쌍 준비
- 개인키는 Terraform과 Git에 입력하지 않고 SSM에 저장
- `Key-Pair-Id`는 CloudFront 공개키 ID이며 key group ID와 구분
- 정상 서명 URL 조회 성공, 만료되거나 변조된 URL은 403 확인

## 6. CI/CD 설정

| 환경 | 워크플로 위치 | GitHub Environment | 배포 허용 ref |
|---|---|---|---|
| 개발 | 각 서비스 저장소 | `dev` | Branch `dev` |
| 스테이징 | CLOUD 저장소 | `staging` | Branch `main` |
| 운영 | 각 서비스 저장소 | `prod` | Branch `main`, Tag `v*.*.*` |

| 서비스 | 개발 | CLOUD 스테이징 | 운영 |
|---|---|---|---|
| BE | `backend-dev-publish.yml` | `backend-staging-deploy.yml` | `backend-prod-publish.yml` |
| FE | `fe-dev-publish.yml` | `fe-staging-deploy.yml` | `fe-prod-publish.yml` |
| AI | `ai-dev-publish.yml` | `ai-staging-deploy.yml` | `ai-prod-publish.yml` |

| 설정 위치 | 필요한 값 |
|---|---|
| 서비스 저장소의 dev와 prod Variables | 해당 서비스의 `AWS_ROLE_ARN` |
| CLOUD staging Variables | `BE_AWS_ROLE_ARN`, `FE_AWS_ROLE_ARN`, `AI_AWS_ROLE_ARN` |
| FE 배포 환경 Variables | `FE_STATIC_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID` |
| FE 빌드 Secret | 개발 `FE_ENV_DEV`, 운영 `FE_ENV`, CLOUD 스테이징 `FE_ENV_STAGING` |
| 비공개 소스 checkout | 필요한 경우 CLOUD의 `STAGING_REPO_TOKEN` |
| GHCR 패키지 권한 | CLOUD Actions에 BE와 AI 읽기, FE 쓰기 허용 |

- 역할 ARN: 해당 환경의 `terraform output github_deploy_role_arns`
- FE 버킷과 배포 ID: `terraform output cloudfront`의 `static_bucket`, `distribution_id`
- OIDC 공급자는 개발 state에서 한 번만 관리하고 다른 환경에서는 조회
- 기존 공급자가 있으면 소유 state를 확인한 뒤 인계. 여러 state에 중복 import 금지
- 최초 ECS 서비스와 CodeDeploy 그룹 생성 및 헬스 체크 통과 후 CD 실행
- 워크플로와 IAM 코드뿐 아니라 GitHub 설정, 실제 배포와 롤백까지 확인

### 수동 배포

| 대상 | 입력과 처리 |
|---|---|
| dev | `digest` 기본값 `latest`, 또는 `sha256:<64자리>` 지정. 재빌드 없음 |
| staging | `version=1.2.3`, BE와 AI는 기존 이미지, FE는 staging 설정으로 빌드 |
| prod | `version=1.2.3`, 기존 운영 이미지 배포 |

- 수동 워크플로는 해당 저장소의 main에 반영되어 있어야 표시
- 릴리즈 Git 태그 `v1.2.3`의 커밋은 서비스 main에 포함돼야 함
- 이미지 태그: BE `v1.2.3`, AI와 FE 운영 `1.2.3`, FE 스테이징 `staging-1.2.3`
- 운영 자동 배포는 `vMAJOR.MINOR.PATCH` 태그로 실행. 일반 main push와 prerelease 제외
- 이미지 태그는 digest로 확정한 뒤 태스크 정의에 반영

### 배포 동작

1. 이미지 준비, FE는 같은 빌드의 정적 파일 먼저 업로드
2. 태스크 정의 등록 후 CodeDeploy 실행
3. 새 태스크 헬스 체크 통과 후 트래픽 전환
4. 실패 시 이전 정상 리비전으로 롤백
5. 구버전 태스크 정리 후 Capacity Provider가 빈 EC2 축소

- 배포 방식: `CodeDeployDefault.ECSAllAtOnce`
- 구버전 태스크 보존: dev와 staging 1분, prod 10분
- 대상 그룹별 5xx가 분당 5건 이상으로 2분 지속되면 배포 중지와 롤백
- 다음 배포는 이전 태스크 세트 정리 후 시작
- 태스크 정의 ARN은 Git이나 Terraform 최초 이미지 입력에 매번 기록하지 않음
- 태스크 실행 설정 변경 시 출력 템플릿을 확인하고 새 태스크 정의로 배포

## 7. 기존 state와 데이터 보존

- 기존 운영 state key 유지, 원격 state 복사나 새 key 이전 금지
- `moved.tf`와 `peering-moved.tf`의 주소 이전, import 대상은 새 plan에서 확인
- 이전 실행 폴더의 저장된 plan 재사용 금지
- 기존 RDS, 데이터 볼륨, ECS 서비스의 예상하지 않은 삭제와 교체가 있으면 적용 중지
- 기존 업로드 버킷 정책 변경 시 현재 권한을 보존하는지 확인
- 옛 v1 RDS 제거는 최종 snapshot과 삭제 대상을 별도 검토. 실제 VPC와 EC2 subnet은 유지
- 기존 Secret은 SSM 전환 확인 후 별도 정리
- v1 피어링과 접근 규칙은 해당 리소스를 쓰는 v1 서비스가 종료된 뒤 정리

## 8. 적용 후 확인

- [ ] DB와 캐시, Kafka 실제 접속
- [ ] 서비스별 태스크 수와 EC2 및 AZ 분산
- [ ] ALB 대상 그룹 헬스 체크
- [ ] CloudFront 경유 페이지, API, BFF와 WebSocket 처리
- [ ] 실제 로그인, 쿠키 전달과 토큰 갱신
- [ ] 서로 다른 BE 사이의 채팅 전달
- [ ] FE 정적 파일과 업로드 이미지 조회
- [ ] 서비스별 실제 CD와 실패 시 롤백
- [ ] SSM 또는 비밀번호 변경 후 새 태스크에 반영

| 출력 | 용도 |
|---|---|
| `services` | ECS 서비스와 태스크 설정 |
| `alb`, `ai_alb` | 외부와 내부 요청 주소 |
| `cloudfront`, `uploads_bucket` | 배포 ID와 파일 버킷 |
| `rds_mysql_endpoint`, `rds_mysql_port`, `valkey` | 운영과 스테이징 데이터 접속 정보 |
| `data` | 개발 데이터 EC2 |

- `terraform validate`와 모의 plan은 실제 기동이나 무중단 전환 검증과 구분
- 서비스 연동 요구: [v2 IaC 문서](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v2-IaC)

## 9. 기존 env의 SSM 일괄 등록

- 작업 위치: CLOUD 저장소 루트
- 도구: Python 3, OpenSSL, AWS CLI
- 원본: dev는 `.env`, prod와 staging은 `.env.prod`
- `V2_ENV`: `dev`, `prod`, `staging` 중 선택
- 기존 파라미터를 덮어쓰므로 AWS 값과 원본을 대조한 뒤 실행
- 원본 env는 수정하지 않으며 비밀값은 임시 JSON으로 전달 후 삭제
- prod와 staging의 DB 설정은 아래 명령에서 제외하고 RDS 모듈이 연결
- 기존 callback의 경로는 유지하므로 등록 후 `/auth/kakao/callback` 주소를 확인
- 원본 env에는 CloudFront 개인키와 Redis 비밀번호 등 필요한 수동 설정이 있어야 함

```sh
cd /Users/dohyun/dev/KTB4-1st-CLOUD
V2_ENV=dev python3 - <<'PY'
import json
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

# 환경에 맞는 원본 파일과 서비스 도메인 선택
environment = os.environ["V2_ENV"]
source_file = {"dev": ".env", "prod": ".env.prod", "staging": ".env.prod"}[environment]
domain = {"dev": "dev.bakkucca.com", "prod": "bakkucca.com", "staging": "staging.bakkucca.com"}[environment]

# 따옴표와 여러 줄 PEM을 포함한 env 파일 읽기
source = {}
lines = iter(Path(source_file).read_text().splitlines())
for line in lines:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    match = re.fullmatch(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
    if not match:
        raise SystemExit("env 파일의 변수 형식을 확인해야 함")
    key, raw = match.groups()
    if raw.startswith(("'", '"')):
        while True:
            try:
                parts = shlex.split(raw, comments=True)
                break
            except ValueError:
                raw += "\n" + next(lines)
        if len(parts) != 1:
            raise SystemExit(f"env 값의 따옴표를 확인해야 함: {key}")
        source[key] = parts[0]
    else:
        source[key] = re.split(r"\s+#", raw, maxsplit=1)[0].rstrip()

def service_url(value):
    url = urlsplit(value)
    if not url.scheme or not url.netloc:
        raise SystemExit("기존 콜백과 프론트 주소의 URL 형식을 확인해야 함")
    return urlunsplit(("https", domain, url.path, url.query, url.fragment))

# v2의 수동 설정만 구성
values = {
    "be": {
        "SPRING_PROFILES_ACTIVE": "prod",
        "AWS_REGION": "ap-northeast-2",
        "CORS_ALLOWED_ORIGINS": f"https://{domain}",
        "DB_USERNAME": source["MYSQL_USER"],
        "DB_PASSWORD": source["MYSQL_PASSWORD"],
        "JAVA_TOOL_OPTIONS": "-Xms256m -Xmx1024m -XX:MaxMetaspaceSize=192m",
        "SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE": "60s",
        "KAKAO_CLIENT_ID": source["KAKAO_CLIENT_ID"],
        "KAKAO_REDIRECT_URI": service_url(source["KAKAO_REDIRECT_URI"]),
        "FRONTEND_REDIRECT_URI": service_url(source["FRONTEND_REDIRECT_URI"]),
        "PROMETHEUS_AUTH_USERNAME": source["PROMETHEUS_AUTH_USERNAME"],
        "CLOUDFRONT_SIGNED_URL_DURATION_SECONDS": "3600",
    },
    "fe": {"NODE_ENV": "production", "PORT": "3000", "HOSTNAME": "0.0.0.0", "NODE_OPTIONS": "--max-old-space-size=1024"},
    "ai": {},
    "data": {"MYSQL_DATABASE": source["MYSQL_DATABASE"], "MYSQL_ROOT_PASSWORD": source["MYSQL_ROOT_PASSWORD"]},
}
if environment != "dev":
    values.pop("data")
    values["be"].pop("DB_USERNAME")
    values["be"].pop("DB_PASSWORD")
if environment == "prod":
    values["be"]["CORS_ALLOWED_ORIGINS"] += ",https://www.bakkucca.com"
    values["be"]["AWS_S3_BUCKET"] = source["AWS_S3_BUCKET"]
secure_keys = {
    "DB_PASSWORD", "MYSQL_ROOT_PASSWORD", "JWT_SECRET", "KAKAO_CLIENT_SECRET",
    "PROMETHEUS_AUTH_PASSWORD", "CLOUDFRONT_PRIVATE_KEY_PEM", "SPRING_DATA_REDIS_PASSWORD",
    "KAKAO_REST_API_KEY", "DISCORD_WEBHOOK_URL", "ANTHROPIC_API_KEY",
}
for service, keys in {
    "be": ["JWT_SECRET", "KAKAO_CLIENT_SECRET", "PROMETHEUS_AUTH_PASSWORD", "CLOUDFRONT_PRIVATE_KEY_PEM", "SPRING_DATA_REDIS_PASSWORD"],
    "fe": ["KAKAO_REST_API_KEY", "DISCORD_WEBHOOK_URL"],
    "ai": ["ANTHROPIC_API_KEY"],
}.items():
    values[service].update({key: source[key] for key in keys})
    values[service]["TZ"] = "Asia/Seoul"

# 기존 개인키에서 공개키 추출
private_key = values["be"]["CLOUDFRONT_PRIVATE_KEY_PEM"].replace("\\n", "\n")
result = subprocess.run(["openssl", "pkey", "-pubout"], input=private_key, text=True, capture_output=True)
if result.returncode:
    raise SystemExit("CloudFront 개인키의 PEM 형식을 확인해야 함")
values["be"]["CLOUDFRONT_PRIVATE_KEY_PEM"] = private_key
values["be"]["CLOUDFRONT_PUBLIC_KEY_PEM"] = result.stdout
if any(not value.strip() for entries in values.values() for value in entries.values()):
    raise SystemExit("등록할 값이 비어 있어 중단")

# 임시 JSON으로 지정한 환경의 파라미터만 등록
for service, entries in values.items():
    for key, value in entries.items():
        name = f"/bakkucca-v2-{environment}/{service}/{key}"
        kind = "SecureString" if key in secure_keys else "String"
        payload = {"Name": name, "Type": kind, "Value": value, "Tier": "Standard", "Overwrite": True}
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as request:
            json.dump(payload, request)
            request.flush()
            result = subprocess.run(
                ["aws", "ssm", "put-parameter", "--region", "ap-northeast-2", "--cli-input-json", f"file://{request.name}", "--no-cli-pager"],
                text=True, capture_output=True,
            )
        if result.returncode:
            raise SystemExit(f"등록 실패: {name}, AWS 인증과 권한 및 파라미터 유형 확인 필요")
        print(f"{kind}: {name}")
PY
```
