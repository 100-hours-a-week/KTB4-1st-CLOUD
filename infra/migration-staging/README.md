# v1 복제 환경과 DB 전환 리허설

- 목적: 여러 사용자 흐름과 채팅을 유지하며 EC2 MySQL → 스테이징 RDS 전환과 DB 롤백 검증
- 변경 대상: BE의 DB 연결
- 후속 작업: [v2 스테이징 인프라 전환](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v2-Staging)

| 구성 | 내용 |
|---|---|
| v1 복제본 | 기본 VPC의 `t4g.small` 한 대에서 FE, BE, AI, MySQL, Nginx 실행 |
| 격리 | 시험용 SG, IAM 역할과 업로드 버킷 사용 |
| Terraform state | `migration/staging-v1/terraform.tfstate` |
| 시험 범위 | 그룹 생성, 검색, 물품 목록과 상세 조회, 수정과 삭제, 교환 요청과 취소, 두 사용자 STOMP 채팅 |
| 제외 범위 | AI 검수와 시세 호출이 필요한 물품 등록, 실제 OAuth, FE와 AI 기능, Kafka 소비, 전체 테이블 정합성 |
| Kafka와 Redis | 이 Terraform에서 배포하지 않음. 시험 Compose의 Kafka 주소는 빈 값 |
| 디스크 | EC2 종료 시 루트 EBS 보존, 볼륨 정리는 별도 확인 |

## 1. 실행 위치와 순서

| 위치 | 실행할 작업 |
|---|---|
| 작업 PC의 CLOUD 저장소 루트 | Terraform 적용과 출력 조회 |
| 마이그레이션용 EC2의 같은 Bash 세션 | BE 설정, 복제 준비, 데이터 복사, DB 전환과 검증 |
| 마이그레이션용 EC2의 별도 SSH 세션 | k6 트래픽 유지 |

1. v1 복제본 배포와 빈 시험 DB 시드 입력
2. 스테이징 RDS와 복제 네트워크 구성
3. 마이그레이션용 BE 배포
4. MySQL 연결 proxy 준비
5. 별도 SSH 세션에서 트래픽 시작
6. 트래픽을 유지하며 데이터 복사, binlog 복제와 DB 전환
7. 성공한 쓰기 대조 후 DB 롤백 검증

### 작업 PC: 인프라 생성

```bash
terraform -chdir=infra/migration-staging init
terraform -chdir=infra/migration-staging plan -out=deploy.tfplan
terraform -chdir=infra/migration-staging apply deploy.tfplan
terraform -chdir=infra/migration-staging output
```

### 마이그레이션용 EC2: Compose 기동과 시드 입력

- 릴리즈 폴더에서 실행
- `.env.shared`에 시험용 DB 비밀번호와 JWT 키, 허용된 staging SSM 설정 사용
- 시드는 빈 시험 DB에 한 번만 입력
- `loadtest/migration/seed.py`로 테이블별 최대 50건의 소량 시드 생성. 사용자·그룹·물품·이미지·채팅 메시지는 각각 50건, 채팅방은 5개
- 기존 대량 시험 DB에 추가 입력하면 데이터가 줄어들지 않음. 초기화·재입력은 시험 DB와 보존 범위를 확인한 뒤 별도 수행
- Flyway 스키마와 이력은 유지

```bash
docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  up -d --wait mysql springboot fastapi nextjs nginx
```

```bash
python3 loadtest/migration/seed.py | sudo docker exec -i mysql sh -c \
  'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql -uroot "$MYSQL_DATABASE"'
```

### 배포 이미지

| 환경변수 | 지정할 이미지 |
|---|---|
| `SPRINGBOOT_IMAGE` | 마이그레이션 관리자 API를 제공하는 ARM64 BE 이미지 |
| `NEXTJS_IMAGE` | 스테이징 주소로 빌드한 FE 이미지 |
| `FASTAPI_IMAGE` | 시험할 AI 릴리즈 이미지 |

- BE 공식 태그 예시: `ghcr.io/100-hours-a-week/ktb4-1st-be:v2.0.0`
- AI 공식 태그 예시: `ghcr.io/100-hours-a-week/ktb4_1st_ai:2.0.0`
- 실제 버전은 릴리즈 manifest 확인, BE 태그의 `v` 접두사 유지
- `bakkucca-*-rehearsal:2.0.0`은 마이그레이션용 EC2의 로컬 별칭이며 다른 서버에서 pull 불가
- 게시된 FE `2.0.0`에는 운영 Kakao callback이 포함되어 있으므로 시험용 FE 유지
- `NEXT_PUBLIC_*` 변경은 FE 재빌드 필요
- 비공개 이미지 pull 전 필요하면 `sudo docker login ghcr.io` 실행
- BE 교체 명령은 4절 사용. 기존 DB 비밀번호와 JWT 키 유지
- 시험 Nginx는 자체 서명 인증서 사용. 실제 OAuth 검증에는 시험 도메인과 신뢰할 수 있는 인증서, Kakao callback 설정 필요

## 3. 작업 PC: 스테이징 RDS 우선 구성

- 기존 v2 staging root의 VPC, private subnet 두 개, BE SG와 RDS 모듈 사용
- 아래 target plan은 최초 RDS 구성용이며 ECS, Valkey, ALB와 CloudFront 생성은 제외
- 기존 `terraform.tfvars.json`이 있으면 다른 입력을 보존하며 `v1_network` 병합. 아래 파일 생성 명령으로 덮어쓰지 않음

```bash
terraform -chdir=infra/migration-staging output -json v1_network |
  python3 -c 'import json,sys; json.dump({"v1_network":json.load(sys.stdin)},sys.stdout)' \
  > infra/v2/environments/staging/terraform.tfvars.json
terraform -chdir=infra/v2/environments/staging init
terraform -chdir=infra/v2/environments/staging plan -out=rds-first.tfplan \
  -target=module.rds \
  -target=module.platform.aws_route_table_association.private \
  -target=aws_vpc_peering_connection.v1_to_v2 \
  -target=aws_route.rds_to_v1 -target=aws_route.v1_to_rds \
  -target=aws_vpc_security_group_ingress_rule.rds_from_v1 \
  -target=aws_vpc_security_group_egress_rule.rds_to_v1 \
  -target=aws_vpc_security_group_ingress_rule.v1_from_rds
terraform -chdir=infra/v2/environments/staging apply rds-first.tfplan
```

- RDS 구성: MySQL 8.4, Multi-AZ, 암호화, 백업과 삭제 방지
- 이후 전체 인프라 적용은 target 없이 plan 검토
- 기존 `v1_network` 유지, DNS가 CloudFront로 연결되는 시점 별도 확인

## 4. 마이그레이션용 EC2: 마이그레이션용 BE 배포

### 접속

```bash
terraform -chdir=infra/migration-staging output instances
terraform -chdir=infra/v2/environments/staging output -raw rds_mysql_endpoint
ssh -i ~/.ssh/bakkucca_v1 ec2-user@<source의-public_ip>
```

- 실제 릴리즈 폴더 사용, `/opt/app/current` 경로를 가정하지 않음
- 해당 폴더에 최신 `scripts/mysql-rds-*.sh`와 `loadtest/migration/` 준비

```bash
bash
cd /opt/app/releases/rehearsal-2.0.0
sudo dnf install -y socat mariadb105
sudoedit /opt/app/shared/.env.shared
```

### 환경변수 설정

| 항목 | 확인 위치 또는 설정 |
|---|---|
| RDS 호스트와 포트 | RDS 콘솔의 `bakkucca-v2-staging-mysql` 연결 정보 |
| DB 이름 | `market` |
| RDS 계정 | 마스터 계정 `admin` |
| 비밀번호 | RDS master secret의 `password` 값 |
| 풀 크기 | 시험용 최대 8, 최소 유휴 2 |

- 기존 환경 파일에 아래 항목 추가, root 소유와 권한 600 유지
- 환경 파일을 `source`하거나 비밀값 출력 금지
- Compose가 `--env-file`로 읽고 migration override가 BE에 주입

```dotenv
SPRINGBOOT_IMAGE=<마이그레이션 BE 이미지 digest>
MIGRATION_RDS_DB_URL=jdbc:mysql://<RDS 호스트>:3306/market?sslMode=REQUIRED
MIGRATION_RDS_DB_USERNAME=<RDS 계정>
MIGRATION_RDS_DB_PASSWORD=<RDS 비밀번호>
MIGRATION_DB_MAX_POOL_SIZE=8
MIGRATION_DB_MIN_IDLE=2
```

### BE 컨테이너 재생성

- `docker-compose.rehearsal.yml`: 시험용 설정
- `docker-compose.migration.yml`: DB 라우팅과 쓰기 barrier용 migration 프로필

```bash
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  -f docker-compose.migration.yml pull springboot
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  -f docker-compose.migration.yml up -d --no-deps --wait springboot
sudo docker exec springboot sh -c '
  if command -v curl >/dev/null; then
    curl -i -X POST http://127.0.0.1:8080/internal/admin/migration/health?target=RDS
  else
    wget -S -O- --post-data="" http://127.0.0.1:8080/internal/admin/migration/health?target=RDS
  fi'
```

## 5. 마이그레이션용 EC2: RDS → MySQL 복제 연결 준비

| 작업 | 확인 조건 |
|---|---|
| socat proxy 구성 | EC2 private IP의 3306 → MySQL 컨테이너 전달, 컨테이너 재생성 없음 |
| 네트워크 | EC2와 RDS 사이 양방향 route와 TCP 3306 SG 허용 |
| 로컬 연결 | `mysqladmin ping` 성공, 3306 listener 확인 |
| 복제 계정 host | RDS subnet CIDR가 아닌 실제 Docker bridge gateway IP 사용 |
| 실제 RDS 연결 | 7절에서 외부 복제 시작 후 IO와 SQL 상태 확인 |

- 로컬 연결 실패 시 다음 단계 중지
- Docker 네트워크 재생성 시 gateway 재확인

## 6. 별도 SSH 세션: 트래픽 실행

마이그레이션용 EC2에서 실행한다. 인증 키·허용 Origin 조회와 시험 ID·결과 폴더 생성은 자동 처리한다.

```bash
bash /opt/app/releases/rehearsal-2.0.0/loadtest/migration/run.sh
```

- 기본: 목록 조회 초당 1회, 수정·삭제·교환 흐름 총 10회 자동 분산, 채팅 2쌍 송수신
- 최대 30분 실행하며, DB 전환과 확인을 마치면 Ctrl+C로 종료 가능
- 부하 실행 중 다른 SSH 세션에서 7~8절의 DB 복제·전환 수행
- 결과는 릴리즈 폴더의 `results/<시험 ID>/`에 저장. 출력된 시험 ID로 9절 검증 수행
- 수동 종료 시 실행한 구간만 검증하며, 응답 없는 요청·메시지 누락은 실패로 판정
- 반복 실행 전 시험 DB를 초기 시드 상태로 복원. 운영 서버에서는 실행하지 않음

## 7. 주 SSH 세션: 데이터 복사와 binlog 복제

### 사전 확인

- DDL 변경 중지
- 원본 설정: `log_bin=ON`, 고유 `server_id`, `binlog_format=ROW`, `binlog_row_image=FULL`
- binlog 보존 시간 확보
- 원본과 RDS의 MySQL 8.4, charset, collation, time zone과 SQL mode 비교
- 빈 시험 RDS에서만 복원. 이관 완료 DB에 재실행 금지
- 기존 migration 상태 디렉터리를 지워 처음부터 재실행 금지
- 트래픽은 데이터 복사부터 8절 전환 완료까지 유지

### 7.1 접속 변수 준비

```bash
# [마이그레이션용 EC2 ec2-user] 위에서 지정한 릴리즈 폴더의 같은 Bash 세션에서 실행한다.
set -euo pipefail
export EC2_PRIVATE_IP="$(hostname -I | awk '{print $1}')"
export MYSQL_NETWORK="$(sudo docker inspect mysql --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk '/backend-net$/ {print; exit}')"
export MYSQL_DATABASE='market'
export RDS_HOST="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_URL" {print $2}' | sed -E 's#jdbc:mysql://([^:/]+).*#\1#')"
export RDS_USER="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_USERNAME" {print $2}')"
export RDS_PASSWORD="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}')"
export EC2_MYSQL_PASSWORD="$(sudo docker inspect mysql --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MYSQL_ROOT_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}')"
export REPL_USER='repl_user'
export REPL_PASSWORD="$(openssl rand -hex 16)"
export REVERSE_REPL_USER='reverse_repl'
export REVERSE_REPL_PASSWORD="$(openssl rand -hex 16)"
export DOCKER_BRIDGE_GATEWAY="$(sudo docker network inspect "$MYSQL_NETWORK" -f '{{(index .IPAM.Config 0).Gateway}}')"
export DUMP_FILE="/tmp/mysql-migration-${MYSQL_DATABASE}.sql"
```

- 비밀번호는 현재 세션의 환경변수로 유지하고 출력 금지

### 7.2 데이터 복사와 복제

- 공통 명령: [DB 마이그레이션 가이드](../../docs/v1-db-migration-guide.md)의 「무중단 이관」 2~7번
- 같은 Bash 세션에서 7.1절 변수를 사용
- 데이터 복사와 복제 완료 후 이 문서의 8절 진행

| 순서 | 작업 | 진행 조건 |
|---|---|---|
| 1 | 원본 MySQL 복제 계정 생성 | 쓰기 가능한 상태에서 `prepare-drain` 전에 한 번만 실행, host는 Docker bridge gateway |
| 2 | RDS 역방향 복제 계정 생성 | 마이그레이션용 EC2 private IP만 접속 허용, RDS binlog 보존 시간 확보 |
| 3 | 원본 덤프 생성 | DDL 중지, 덤프 파일과 시작 binlog 좌표 확인 |
| 4 | 빈 시험 RDS에 복원 | 복원 성공, 핵심 테이블과 DDL, Flyway 이력 대조 |
| 5 | 덤프 좌표부터 외부 복제 시작 | RDS에서 원본 MySQL 연결 |
| 6 | 복제 상태 확인 | IO와 SQL 모두 `Yes`, 오류 없음, 지연 감소 또는 0, 좌표 정상 진행 |

- 복원 실패나 데이터 불일치, 복제 오류 시 다음 단계 중지
- 복제 지연 0만으로 DB 전환 완료 판단 금지
- 비동기 조회수와 검색 이력 저장이 완료된 뒤 최종 복제 위치 대조

## 8. 주 SSH 세션: BE의 DB 연결을 RDS로 전환

- BE 재시작 없이 관리자 API로 DB 연결 변경
- barrier: 기존 쓰기 완료를 기다리고 새 쓰기는 전환 완료까지 대기시키는 제어
- 각 명령 성공 확인 후 다음 명령 실행

```bash
export RDS_PORT=3306 EC2_CONTAINER=mysql WAS_ADMIN_CONTAINER=springboot
export WAS_ADMIN_URL=http://127.0.0.1:8080/internal/admin/migration
export MIGRATION_STATE_DIR=/var/lib/bakkucca/mysql-migration
export MIGRATION_TIMEOUT_SECONDS=900 POLL_SECONDS=2
sudo install -d -m 700 "$MIGRATION_STATE_DIR"
run_migration() {
  sudo env \
    RDS_HOST="$RDS_HOST" RDS_PORT="$RDS_PORT" \
    RDS_USER="$RDS_USER" RDS_PASSWORD="$RDS_PASSWORD" \
    EC2_MYSQL_PASSWORD="$EC2_MYSQL_PASSWORD" EC2_CONTAINER="$EC2_CONTAINER" \
    WAS_ADMIN_CONTAINER="$WAS_ADMIN_CONTAINER" WAS_ADMIN_URL="$WAS_ADMIN_URL" \
    REVERSE_REPL_USER="$REVERSE_REPL_USER" REVERSE_REPL_PASSWORD="$REVERSE_REPL_PASSWORD" \
    EC2_REVERSE_REPLICA_READY="${EC2_REVERSE_REPLICA_READY:-no}" \
    MIGRATION_STATE_DIR="$MIGRATION_STATE_DIR" \
    MIGRATION_TIMEOUT_SECONDS="$MIGRATION_TIMEOUT_SECONDS" POLL_SECONDS="$POLL_SECONDS" \
    bash "$@"
}
run_migration scripts/mysql-rds-validate.sh
run_migration scripts/mysql-rds-prepare-drain.sh
run_migration scripts/mysql-rds-promote.sh
run_migration scripts/mysql-rds-arm-reverse-replica.sh
run_migration scripts/mysql-rds-switch-traffic.sh
```

| 스크립트 | 역할 |
|---|---|
| `validate` | DB 연결과 복제 사전 확인 |
| `prepare-drain` | 쓰기 barrier 설정, 원본 쓰기 차단과 최종 동기화 |
| `promote` | RDS 승격, barrier 유지 |
| `arm-reverse-replica` | RDS → EC2 역방향 복제 구성 |
| `switch-traffic` | BE의 RDS 사용 검증 후 barrier 해제 |

| 실패 시점 | 조치 |
|---|---|
| RDS 승격 전 | 후속 명령 중지, 원인 확인 후 `run_migration scripts/mysql-rds-abort.sh` |
| RDS 승격 후 | abort 금지, barrier 유지 후 담당자 복구 |

## 9. 주 SSH 세션: 데이터 대조와 DB 롤백

### 데이터 대조

- k6 종료와 BE 비동기 검색 이력 및 조회수 저장 완료 후 실행
- 이 검증은 스키마 버전 4의 원장과 JSON payload가 포함된 새 `export.sql`을 함께 사용
- 수동 종료 기록이 있으면 실행한 구간만 검증하며, 아직 취소하지 않은 교환은 PENDING 상태로 대조
- 수동 종료 결과가 통과해도 DB 전환 전·중·후 트래픽을 모두 포함했는지는 실행 시각으로 별도 확인
- 기존 그룹 생성과 검색만 수행한 결과 파일은 새 검증기에 입력하지 않음
- 역방향 복제 IO와 SQL 모두 `Yes`, 오류 없음, 지연 0 확인
- 최종 RDS binlog 좌표까지 EC2 반영 확인, 비교 중 추가 쓰기 금지
- `RUN_ID`에는 6절 트래픽 실행 ID 입력

```bash
export RUN_ID='<6절 트래픽의 RUN_ID>'
sudo install -d -o "$(id -u)" -g "$(id -g)" "results/$RUN_ID"
sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql \
  mysql -uroot -e 'SHOW REPLICA STATUS\G'
sudo docker exec -i -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql \
  mysql -uroot --batch --raw --skip-column-names market \
  < loadtest/migration/export.sql > "results/$RUN_ID/source.tsv"
MYSQL_PWD="$RDS_PASSWORD" mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
  --batch --raw --skip-column-names market \
  < loadtest/migration/export.sql > "results/$RUN_ID/rds.tsv"
python3 loadtest/migration/verify.py --run "$RUN_ID" \
  --ledger "results/$RUN_ID/$RUN_ID-ledger.jsonl" \
  --summary "results/$RUN_ID/$RUN_ID-summary.json" \
  --source "results/$RUN_ID/source.tsv" --rds "results/$RUN_ID/rds.tsv"
```

| 항목 | 합격 조건 |
|---|---|
| 검증 프로그램 | `passed: true`, 종료 코드 0 |
| 요청 | 실패와 timeout 없음 |
| 수정과 삭제 | 변경한 내용과 수량, 이미지와 그룹 연결, soft delete 상태 일치 |
| 교환 | 새 교환의 취소 상태, 제안 물품, 닫힌 채팅방과 참여자 일치 |
| 채팅 | 송신마다 두 사용자에게 정확히 한 번 도착, 수신한 message ID와 DB 저장 ID 일치 |
| 비동기 저장 | 검색 이력과 물품 조회수 반영 |
| 부하 원장 | 예정한 모든 API 세션과 13개 단계 완료, 누락된 단계와 중복 요청 없음 |
| DB 비교 | 시험 데이터와 ID가 두 DB에서 일치, 양쪽에 같은 손실이 있어도 실패 |

### RDS → EC2 DB 롤백

- 최신 RDS 쓰기까지 EC2에 반영됐다고 확인한 경우에만 실행

```bash
export EC2_REVERSE_REPLICA_READY=yes
run_migration scripts/mysql-rds-rollback.sh
```

- 롤백 후 BE의 EC2 DB 사용과 API 읽기 및 쓰기 확인
- 롤백 후 EC2 쓰기가 RDS에 자동 복제된다고 가정하지 않음
- 역방향 복제 지연 또는 오류, RDS 연결 실패 시 강제 전환 금지
- MySQL 컨테이너와 데이터 볼륨, migration 상태는 결과 확인 전 삭제 금지
- 상세 DB 복구와 정리 절차: [DB 마이그레이션 가이드](../../docs/v1-db-migration-guide.md)
- 이 문서의 DB 롤백과 v2 ECS → v1 인프라 롤백은 별도 작업

## 10. 코드 자체 검증

- 아래 명령은 서버에 트래픽을 보내지 않는 로컬 검증
- 결과 검증기가 요청 실패·데이터 누락·중복을 성공으로 판정하지 않는지 확인
- 실제 k6 실행과 DB 전환 검증을 대신하지 않음

```bash
python3 -m unittest discover -s loadtest/migration -p test_verify.py -v
```
