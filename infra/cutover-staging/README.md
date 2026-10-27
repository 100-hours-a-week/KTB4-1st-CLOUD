# 인프라 전환용 v1 복제본

- 목적: 별도 v1 EC2에서 v2 ECS로 요청 원본 전환·롤백 시험
- 선행 조건: 시험용 v2 ECS·ALB·Kafka·Valkey 준비
- v2 시험 자원은 `infra/v2/environments/staging`으로 재구축. 기존 RDS·DNS·CloudFront는 준비 절차에 따라 보존
- DB 복제본·데이터 이관·DB 롤백은 DB 담당자 관리

| 구분 | 내용 |
|---|---|
| 애플리케이션 | EC2 한 대에서 FE / BE / AI / Nginx 실행 |
| DB | v2 staging RDS 사용 |
| 공통 자원 | 별도로 준비한 시험용 Kafka / Valkey |
| 요청 경로 | `staging.bakkucca.com` → CloudFront → `v1-origin.staging.bakkucca.com` → EC2 |
| Terraform 범위 | EC2 / IAM 생성, Docker / Compose 설치 |
| 수동 준비 | 배포 파일, staging 환경변수, 인증서, DNS / CloudFront 연결 |

**EC2 생성 → 배포 파일 전달 → 환경변수 / 인증서 준비 → 앱 기동 → CloudFront 연결**

전환과 롤백 시험은 [loadtest/cutover](../../loadtest/cutover/README.md)에서 진행

## 경로

| 항목 | 위치 |
|---|---|
| 배포 파일 | `/opt/app/releases/cutover-2.0.2/` |
| 환경파일 | `/opt/app/shared/.env.shared` — root 소유, 권한 600 |
| 인증서 | `/opt/app/shared/certs/fullchain.pem`, `privkey.pem` |
| Terraform state | `cutover/staging-v1/terraform.tfstate` — 기존 state 재사용 시 같은 EC2 관리 |

## 1. EC2 생성

- 선행 자원: 기본 VPC, 서브넷, SG, 키페어, staging SSM, RDS Secret
- 선행 네트워크: v1 ↔ v2 피어링, RDS / Kafka / Valkey 접근 규칙
- **Terraform 적용만으로 앱 배포 완료되지 않음**

<details>
<summary>EC2 생성 명령</summary>

```bash
terraform -chdir=infra/cutover-staging init
terraform -chdir=infra/cutover-staging plan -out=deploy.tfplan
terraform -chdir=infra/cutover-staging apply deploy.tfplan
terraform -chdir=infra/cutover-staging output instances
```

</details>

## 2. 배포 파일 전달

- `CUTOVER_HOST`: Terraform 출력의 새 EC2 공인 IP
- 전달 파일: 기본 Compose, cutover override, Nginx 설정
- 소스 빌드 없음 — GHCR 이미지 사용

<details>
<summary>파일 전달 명령</summary>

```bash
export CUTOVER_HOST=새_복제본_공인_IP
ssh -i ~/.ssh/bakkucca_v1 ec2-user@"$CUTOVER_HOST" \
  'sudo mkdir -p /opt/app/releases/cutover-2.0.2'
tar -czf - docker-compose.yml \
  infra/cutover-staging/docker-compose.override.yml \
  infra/cutover-staging/nginx.conf | \
  ssh -i ~/.ssh/bakkucca_v1 ec2-user@"$CUTOVER_HOST" \
    'sudo tar -xzf - -C /opt/app/releases/cutover-2.0.2'
```

</details>

## 3. 환경변수 / 인증서 준비 — EC2

- `.env.shared`에 `KEY=value` 형식으로 작성 — 기존 파일은 필요한 값만 변경
- **staging 값만 사용 — 운영 비밀값 복사 금지**
- `$`, `#` 등이 포함된 값은 작은따옴표로 감싸기
- 환경파일 `source` 금지 — Compose `--env-file`로 주입
- 인증서: 서비스 도메인과 v1 원본 도메인 모두 유효한 공인 인증서
- 개인키: root 소유, 권한 600 — 별도 갱신 필요

<details>
<summary>환경파일 준비 명령과 설정 예시</summary>

```bash
ssh -i ~/.ssh/bakkucca_v1 ec2-user@"$CUTOVER_HOST"
sudo install -d -m 700 /opt/app/shared/certs
sudo touch /opt/app/shared/.env.shared
sudo chmod 600 /opt/app/shared/.env.shared
sudoedit /opt/app/shared/.env.shared
```

```dotenv
SPRINGBOOT_IMAGE=ghcr.io/100-hours-a-week/ktb4-1st-be:v2.0.2
NEXTJS_IMAGE=ghcr.io/100-hours-a-week/ktb4-1st-fe:2.0.0
FASTAPI_IMAGE=ghcr.io/100-hours-a-week/ktb4_1st_ai:2.0.0
SPRING_PROFILES_ACTIVE=prod
DB_URL=jdbc:mysql://bakkucca-v2-staging-mysql.c9acsiyqqzik.ap-northeast-2.rds.amazonaws.com:3306/market?sslMode=REQUIRED
CORS_ALLOWED_ORIGINS=https://staging.bakkucca.com
AI_BASE_URL=http://fastapi:8000
```

| 환경변수 | 가져올 곳 |
|---|---|
| `DB_USERNAME`, `DB_PASSWORD` | staging RDS의 **구성 → 보안 인증 정보 ARN** → Secrets Manager의 `username`, `password` |
| `KAFKA_BOOTSTRAP_SERVERS` | Parameter Store `/bakkucca-v2-staging/be/KAFKA_BOOTSTRAP_SERVERS` |
| `JWT_SECRET`, `AWS_S3_BUCKET` | Parameter Store `/bakkucca-v2-staging/be/<변수명>` |
| `KAKAO_CLIENT_ID`, `KAKAO_CLIENT_SECRET`, `KAKAO_REDIRECT_URI`, `FRONTEND_REDIRECT_URI` | 같은 staging BE 경로 |
| `PROMETHEUS_AUTH_USERNAME`, `PROMETHEUS_AUTH_PASSWORD` | 같은 staging BE 경로 |
| `SPRING_DATA_REDIS_CLUSTER_NODES`, `SPRING_DATA_REDIS_SSL_ENABLED`, `SPRING_DATA_REDIS_USERNAME`, `SPRING_DATA_REDIS_PASSWORD` | 같은 staging BE 경로 |
| `KAKAO_REST_API_KEY` | `/bakkucca-v2-staging/fe/KAKAO_REST_API_KEY` |
| `ANTHROPIC_API_KEY` | `/bakkucca-v2-staging/ai/ANTHROPIC_API_KEY` |


- override: Flyway / SQL 초기화 비활성화, Hibernate `validate` 고정
- 기본 BE 2.0.2: SimpleBroker 사용 — 서버 간 채팅 시험은 [Pub/Sub 시험 이미지](../../loadtest/cutover/records/pubsub-rehearsal.md) 필요
- FE: 브라우저 OAuth 시험 전 staging callback으로 빌드된 이미지인지 확인

</details>

## 4. 이미지 다운로드 / 기동 — EC2

- 비공개 GHCR 패키지 읽기 권한 필요 — PAT `read:packages`
- FE / BE / AI `healthy`, Nginx `running` 확인
- BE 변경: `.env.shared`의 `SPRINGBOOT_IMAGE` 수정 후 `pull` / `up`
- **`docker restart`만으로 이미지와 환경변수 변경 반영 불가**

<details>
<summary>GHCR 로그인과 앱 기동 명령</summary>

```bash
read -rp 'GitHub 사용자명: ' GHCR_USER
read -rsp 'GHCR PAT: ' GHCR_PAT
printf '%s' "$GHCR_PAT" | sudo docker login ghcr.io -u "$GHCR_USER" --password-stdin
unset GHCR_PAT

cd /opt/app/releases/cutover-2.0.2
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f infra/cutover-staging/docker-compose.override.yml \
  pull fastapi springboot nextjs nginx
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f infra/cutover-staging/docker-compose.override.yml \
  up -d --wait fastapi springboot nextjs nginx
```

- BE만 변경: `pull` / `up`의 서비스 목록을 `springboot`로 지정, `up`에 `--no-deps` 추가

</details>

## 5. CloudFront 연결 / 확인

| 대상 | 설정 |
|---|---|
| Route 53 원본 도메인 | `v1-origin.staging.bakkucca.com` A → 새 EC2 공인 IP |
| 서비스 도메인 | A / AAAA → CloudFront 유지 |
| CloudFront | `EC89XPEZQJIG0`, `v1-app` 원본을 v1 도메인 / HTTPS only로 지정 |
| 기본 / FE 정적 경로 | `v1-app` 선택 |
| 업로드 이미지 | `/images/*` 기존 설정 유지 |
| SG | CloudFront의 HTTPS 접근 허용, 피어링을 통한 RDS 접근 허용 |

```bash
curl -fsS https://staging.bakkucca.com/health
curl -fsS https://staging.bakkucca.com/api/actuator/health/readiness
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
```

- 시험 중 DNS·CloudFront·앱 인프라 변경은 전환 실행자가 관리
- staging 재구축 전 기존 CloudFront의 state 소유권 확인. 적용 plan에서 원본·DNS 변경 대조
- `publish_service_dns=false`: Terraform의 서비스 DNS 생성 보류용 — CloudFront 원본 보호 기능 아님
- Kafka 확인: SSM 주소 주입, TCP 연결, consumer group 참여 / 파티션 할당 — 실제 발행 / 소비와는 별도 검증

## 전환 시험으로 이동

- [시험 준비 / 실행 / 전환 / 롤백 / 결과 확인](../../loadtest/cutover/README.md)
- 2단계 파일 전달에는 시험 코드 미포함 — 별도 복사 필요
- 시험 데이터는 미사용 ID 범위로 새로 준비 — 기존 fixture 재사용 금지
- DB 마이그레이션 복제본과 스크립트는 이 절차에서 변경하지 않음
