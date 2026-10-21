# v1 복제 환경과 DB 전환 리허설

기본 VPC에 FE·BE·AI·MySQL·Nginx용 `t4g.small`과 Kafka용 `t4g.micro`를 생성한다.
운영과 분리한 SG·IAM 역할·업로드 버킷과 `migration/staging-v1/terraform.tfstate`를 사용한다.
Kafka는 dev와 같은 단일 KRaft 브로커, 컨테이너 한도 768MiB다. Redis는 사용하지 않는다.
EC2 종료 시 루트 EBS는 보존되므로 시험 종료 후 볼륨 정리는 별도로 확인한다.

## v1 복제 배포

SSH는 두 EC2 모두 전체 IPv4에서 허용하며 `bakkucca-v1`·`bakkucca-v1-janna` 공개키를 등록한다.
접속 계정은 `ec2-user`다. HTTP·HTTPS는 `terraform.tfvars.json`의 `access_cidrs`로 제한한다.
cloud-init 변경으로 기존 서버를 재생성하지 않으며, 기존 서버의 키 변경은 별도로 반영한다.
FE는 운영 URL이 삽입되지 않도록 같은 릴리즈 소스를 시험용 공개 설정으로 빌드한다.
서비스 이미지는 기존 Compose의 `SPRINGBOOT_IMAGE`, `NEXTJS_IMAGE`, `FASTAPI_IMAGE`로 교체한다.

```bash
terraform -chdir=infra/migration-staging init
terraform -chdir=infra/migration-staging plan -out=deploy.tfplan
terraform -chdir=infra/migration-staging apply deploy.tfplan
terraform -chdir=infra/migration-staging output
```

EC2에서는 기존 `/opt/app/shared/.env.shared`에 시험 설정을 저장하고 릴리즈 폴더에서 실행한다.
비밀값은 EC2가 허용된 staging SSM 경로에서 조회한다. DB 비밀번호와 JWT 키는 시험 전용이다.

```bash
docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  up -d --wait mysql springboot fastapi nextjs nginx
```

기존 v1 시드는 V6에서 삭제한 컬럼을 입력하므로, 마이그레이션용 변환을 거쳐 빈 시험 DB에 한 번만 입력한다.
Flyway 스키마와 이력은 변경하지 않는다.

```bash
python3 loadtest/migration/seed.py | sudo docker exec -i mysql sh -c \
  'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysql -uroot "$MYSQL_DATABASE"'
```

시험 Nginx는 자체 서명 인증서를 사용한다. 실제 OAuth 시험 전 staging 도메인·신뢰할 수 있는
인증서·Kakao redirect URI를 일치시켜야 한다. 인스턴스 기동과 OAuth 성공 검증은 구분한다.

### 이미지 위치와 BE 이미지 교체

`bakkucca-be-rehearsal:2.0.0`, `bakkucca-fe-rehearsal:2.0.0`, `bakkucca-ai-rehearsal:2.0.0`은
초기 시험 배포 때 시험 EC2의 Docker에 만든 로컬 태그다. GHCR에 게시된 이미지 이름이 아니므로
다른 서버에서 이 이름으로 pull할 수 없다. BE·AI는 기존 릴리즈 이미지를 사용했고,
FE는 운영 API·OAuth 주소가 포함되지 않도록 시험용 공개 환경변수로 별도 빌드했다.

이후 BE 교체에는 main 코드로 빌드·게시한 GHCR 시맨틱 버전 이미지를 직접 지정한다.
예를 들어 기존 릴리즈의 BE 참조는 `ghcr.io/100-hours-a-week/ktb4-1st-be:v2.0.0`이다.
버전별 정확한 태그는 릴리즈 manifest를 확인한다. BE 태그의 `v` 접두사를 임의로 빼지 않는다.
FE는 `NEXT_PUBLIC_*`가 빌드 시 포함되므로 운영 이미지를 그대로 사용하기 전에 시험 환경 주소인지 확인한다.

시험 EC2에서 `/opt/app/shared/.env.shared`의 `SPRINGBOOT_IMAGE`만 새 이미지로 수정한다.
기존 DB 비밀번호·JWT 키 등은 유지한다. RDS 마이그레이션 설정은 아래 「접속 및 BE 설정」을 따른다.

```bash
sudoedit /opt/app/shared/.env.shared
# SPRINGBOOT_IMAGE=ghcr.io/100-hours-a-week/ktb4-1st-be:<게시된 버전 태그>

cd /opt/app/releases/rehearsal-2.0.0
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  pull springboot
sudo docker compose --env-file /opt/app/shared/.env.shared \
  -f docker-compose.yml -f loadtest/migration/docker-compose.rehearsal.yml \
  up -d --no-deps --wait springboot
```

비공개 GHCR 이미지라면 pull 전에 `sudo docker login ghcr.io`로 읽기 권한이 있는 계정을 인증한다.
마이그레이션 프로필을 사용하는 BE로 교체할 때는 **위 두 Compose 명령 모두**
`-f docker-compose.migration.yml`을 `pull` 또는 `up` 앞에 추가한다.
이미 migration 프로필로 실행 중이면 교체할 때도 이 파일을 포함해야 한다.
env 수정이나 `docker restart`만으로 새 이미지·환경변수가 반영되지는 않는다.
BE 컨테이너 교체 중 요청 중단이 발생할 수 있으므로 k6는 교체 완료 후 실행한다.

## v2 staging의 RDS 우선 준비

기존 staging root의 VPC·private subnet 두 개·route table·BE SG·RDS 모듈을 사용한다.
다음 명령은 단계별 최초 구성용 target plan이다. ECS·Valkey·ALB·CloudFront는 이 단계에 생성하지 않는다.

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

RDS는 기존 설정대로 MySQL 8.4, Multi-AZ, 암호화, 백업과 삭제 방지를 사용한다.
이후 전체 서비스 단계에서는 target 없이 plan을 검토한다. staging 도메인을 CloudFront로
전환하는 리소스도 있으므로 DNS 전환 시점과 구성을 먼저 확인한다.

## DB 전환 리허설 실행 순서

인프라 생성과 DB 전환은 별도 작업이다. 아래 순서는 **시험용 v1 EC2 → staging RDS**를 대상으로 한다.
FE·AI·Nginx의 배포 위치는 유지하고 BE의 DB 연결 대상만 바꾼다. ECS 이전과 운영 DB 이관은 이 시험 이후 별도로 진행한다.
기존 [DB 마이그레이션 가이드](../../docs/v1-db-migration-guide.md)의 절차를 AL2023 시험 EC2 기준으로 실행한다.

### 기존 DB 마이그레이션 가이드에서 수정된 점

- Ubuntu 명령을 시험 EC2의 AL2023 명령으로 변경
- 시험 EC2·staging RDS의 주소와 실행 경로 사용
- 다른 VPC 사이의 피어링·라우팅·보안그룹 반영
- 기존 문서의 socat 연결, 복제 계정, dump·복원, binlog 복제, 전환·롤백 절차 유지

### 1. 접속 및 BE 설정

로컬 CLOUD 저장소 루트에서 접속 정보를 조회한다. RDS endpoint에는 `:3306`이 포함되므로 JDBC URL에 포트를 중복으로 넣지 않는다.

```bash
terraform -chdir=infra/migration-staging output instances
terraform -chdir=infra/v2/environments/staging output -raw rds_mysql_endpoint
ssh -i ~/.ssh/bakkucca_v1 ec2-user@<source의-public_ip>
```

이후 별도 표시가 없으면 **시험 EC2의 같은 Bash 세션**에서 실행한다.
릴리즈 폴더는 배포한 경로를 사용한다. 아래는 `rehearsal-2.0.0` 배포 기준이며 `/opt/app/current`가 있다고 가정하지 않는다.
필요한 최신 `scripts/mysql-rds-*.sh`와 `loadtest/migration/` 파일도 해당 릴리즈 폴더에 준비한다.

```bash
bash
cd /opt/app/releases/rehearsal-2.0.0
sudo dnf install -y socat mariadb105
sudoedit /opt/app/shared/.env.shared
```

기존 환경변수를 유지하고 다음 항목을 추가·수정한다. RDS 계정·비밀번호는 담당자가 Secrets Manager에서 확인한 값으로 입력한다.
`.env.shared`는 root 소유·권한 600으로 유지하고 `source`하거나 출력하지 않는다.

```dotenv
SPRINGBOOT_IMAGE=<마이그레이션 관리자 API를 제공하는 ARM64 BE 이미지 또는 digest>
MIGRATION_RDS_DB_URL=jdbc:mysql://<RDS 호스트>:3306/market?sslMode=REQUIRED
MIGRATION_RDS_DB_USERNAME=<RDS 계정>
MIGRATION_RDS_DB_PASSWORD=<RDS 비밀번호>
MIGRATION_DB_MAX_POOL_SIZE=8
MIGRATION_DB_MIN_IDLE=2
```

이미지 버전 이름만으로 migration 지원 여부를 판단하지 않는다. BE가 EC2/RDS datasource 라우팅과 쓰기 barrier 관리자 API를 제공해야 한다.
기존 `docker-compose.migration.yml`은 리허설과 운영 이관에 공통으로 사용하고, `docker-compose.rehearsal.yml`은 시험 환경 설정에만 사용한다.

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

BE 재생성 동안 요청 중단이 발생할 수 있으므로 트래픽 주입은 이 배포가 끝난 후 시작한다.
관리자 API의 `404`·연결 거부·인증 오류는 BE 배포부터 해결한다. commit 전 `409`는 API 접근 확인에만 사용하며 RDS 정상 판정으로 보지 않는다.

### 2. RDS → 원본 MySQL 연결 준비

MySQL 컨테이너를 재생성하지 않고 EC2 private IP의 3306을 컨테이너로 전달한다.
이 단계의 로컬 연결 확인과 실제 RDS 복제 연결 확인은 구분한다.

1. EC2에서 다음 값을 설정한다.
   ```bash
   export EC2_PRIVATE_IP="$(hostname -I | awk '{print $1}')"
   export MYSQL_NETWORK="$(sudo docker inspect mysql --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk '/backend-net$/ {print; exit}')"
   export MYSQL_CONTAINER='mysql'
   ```
2. EC2에서 proxy 서비스를 만든다.
   ```bash
   # Amazon Linux 2023 시험 EC2 기준
   sudo dnf install -y socat mariadb105
   sudo tee /usr/local/sbin/mysql-container-proxy.sh >/dev/null <<'SCRIPT'
   #!/usr/bin/env bash
   set -Eeuo pipefail
   IP="$(sudo docker inspect -f "{{with index .NetworkSettings.Networks \"${MYSQL_NETWORK}\"}}{{.IPAddress}}{{end}}" "${MYSQL_CONTAINER}")"
   test -n "$IP"
   exec /usr/bin/socat \
     "TCP-LISTEN:3306,bind=${EC2_PRIVATE_IP},reuseaddr,fork" \
     "TCP:${IP}:3306"
   SCRIPT
   sudo chmod 750 /usr/local/sbin/mysql-container-proxy.sh
   sudo tee /etc/systemd/system/mysql-container-proxy.service >/dev/null <<'UNIT'
   [Unit]
   Description=Expose container MySQL to RDS
   After=docker.service
   Requires=docker.service

   [Service]
   Type=simple
   Environment=EC2_PRIVATE_IP=REPLACE_EC2_PRIVATE_IP
   Environment=MYSQL_CONTAINER=mysql
   Environment=MYSQL_NETWORK=bakkucca_backend-net
   ExecStart=/usr/local/sbin/mysql-container-proxy.sh
   Restart=always
   RestartSec=3
   User=root

   [Install]
   WantedBy=multi-user.target
   UNIT
   sudo sed -i -e "s/REPLACE_EC2_PRIVATE_IP/${EC2_PRIVATE_IP}/" \
     -e "s/Environment=MYSQL_NETWORK=.*/Environment=MYSQL_NETWORK=${MYSQL_NETWORK}/" \
     /etc/systemd/system/mysql-container-proxy.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now mysql-container-proxy
   sudo systemctl status --no-pager mysql-container-proxy
   ```
   운영 애플리케이션의 `.env`를 `source`해서 이 값을 주입하지 않는다. 비밀번호에
   shell 특수문자가 포함되면 `.env`가 명령으로 해석될 수 있으므로, 아래 마이그레이션
   환경 변수는 안내된 `export` 블록에 값을 직접 입력하거나 안전한 비밀 저장소에서
   개별적으로 주입한다.
3. EC2에서 로컬 listener와 proxy 대상만 확인한다. 아래 명령은 EC2에서 실행하며, RDS에서 실행하는 명령이 아니다. 이 검사는 EC2 포트가 열려 있는지와 proxy가 컨테이너 MySQL로 연결되는지만 확인한다.
   ```bash
   mysqladmin --protocol=tcp -h "$EC2_PRIVATE_IP" -P 3306 \
     -u root -p --connect-timeout=5 ping
   sudo ss -ltnp | grep ':3306'
   ```
   EC2 내부 확인이 실패하면 다음 단계로 진행하지 않는다. EC2 보안 그룹은 v2 VPC CIDR에서
   3306을 허용하고, RDS 보안 그룹은 v1 VPC CIDR에서 3306을 허용한다.<br>
   RDS에는 SSH나 `mysqladmin`을 실행할 셸이 없으므로 RDS에서 EC2로의 실제 연결 검증은 RDS 외부 복제를 설정하고 시작한 뒤 수행한다. <br>
   `mysql.rds_set_external_source`와 `mysql.rds_start_replication`은 RDS에 접속한 `mysql` 클라이언트에서 실행한다.<br>
   RDS가 EC2의 `${EC2_PRIVATE_IP}:3306`에 접근하지 못하면 복제가 시작되지 않거나 `Last_IO_Error`가 기록된다.

   `socat`을 통과하면 컨테이너 안의 MySQL이 보는 접속 출발지는 RDS의 IP가 아니라 Docker bridge gateway IP가 된다. 따라서 복제 계정의 MySQL host 값은 RDS subnet CIDR가 아니라 아래에서 확인한 `${DOCKER_BRIDGE_GATEWAY}`여야 한다.
   ```bash
   export DOCKER_BRIDGE_GATEWAY="$(
     sudo docker network inspect "$MYSQL_NETWORK" \
       -f '{{(index .IPAM.Config 0).Gateway}}'
   )"
   test -n "$DOCKER_BRIDGE_GATEWAY"
   echo "$DOCKER_BRIDGE_GATEWAY"
   ```
   출력된 현재 gateway 값을 복제 계정 생성 단계에서 사용한다. Docker 네트워크를 재생성하면 gateway가 달라질 수 있으므로 `172.18.0.1` 같은 값을 문서에서 추정하거나 고정하지 않는다. MySQL host 제한은 이 Docker gateway IP로 최소화하고, 외부 접근 제한은 보안 그룹의 RDS 보안 그룹 전용 3306 ingress로 적용한다.


### 3. 데이터 복사와 binlog 복제

스냅샷 복사 중에도 쓰기가 계속 발생하는 조건을 시험하려면 **먼저 4번의 트래픽을 별도 SSH 터미널에서 시작한 후** 이 절을 실행한다.
트래픽은 덤프·복원·복제·5번 전환이 끝날 때까지 유지한다. 30분이 부족하면 총 세션 4,000회 이내에서 `MINUTES`를 늘린다.

DDL 변경을 중지하고 원본 MySQL의 `log_bin=ON`, 고유한 `server_id`, `binlog_format=ROW`,
`binlog_row_image=FULL`과 충분한 binlog 보존 시간을 확인한다. 원본과 RDS는 MySQL 8.4이며 문자 집합·collation·time zone·SQL mode를 비교한다.
아래 복원은 **빈 시험 RDS**에서만 실행한다. 이미 이관한 DB에 재실행하거나 기존 migration 상태 디렉터리를 지워 처음부터 실행하지 않는다.

1. 필요한 값을 한 번만 설정한다.
   ```bash
   # [시험 EC2 ec2-user] 위에서 지정한 릴리즈 폴더의 같은 Bash 세션에서 실행한다.
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
   이 블록은 운영 `.env`를 `source`하지 않고 실행한다. 비밀번호는 명령행에 직접 입력하지 않으며, 이 SSH 세션에서만 환경변수로 유지한다.
2. **[시험 EC2 ec2-user, `prepare-drain` 실행 전 1회만]** 원본 EC2 컨테이너에서 RDS가 접근할 복제 계정을 만든다. Docker bridge를 통과한 RDS 연결은 MySQL에서 `${DOCKER_BRIDGE_GATEWAY}`로 보이므로 이 정확한 IP를 host로 사용한다. RDS가 직접 컨테이너에 연결하는 구조가 아니므로 RDS subnet CIDR를 host 값으로 사용하지 않는다. 이 명령은 EC2 MySQL이 쓰기 가능한 상태일 때만 실행한다. 이미 5번 DB 연결 전환까지 완료했다면 이 단계를 다시 실행하지 않는다.
   ```bash
   sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql mysql -uroot -e "
   CREATE USER IF NOT EXISTS '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}' IDENTIFIED BY '${REPL_PASSWORD}';
   ALTER USER '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}' IDENTIFIED BY '${REPL_PASSWORD}';
   GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}';
   FLUSH PRIVILEGES;"
   ```
3. **[시험 EC2 ec2-user → RDS]** RDS에서 rollback용 계정을 만든다. RDS 셸이 아니라 시험 EC2에서 아래 `mysql` 명령을 실행한다. 이 계정은 EC2의 실제 사설 IP만 허용한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e "
   CALL mysql.rds_set_configuration('binlog retention hours', 168);
   CREATE USER IF NOT EXISTS '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}' IDENTIFIED BY '${REVERSE_REPL_PASSWORD}';
   GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}';
   FLUSH PRIVILEGES;
   CALL mysql.rds_show_configuration;"
   ```
4. **[시험 EC2 ec2-user + MySQL container]** 데이터 덤프를 생성한다. 이 명령은 DDL을 동결한 상태에서 실행한다.
   ```bash
   set -euo pipefail
   sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql \
     mysqldump -uroot \
     --databases "$MYSQL_DATABASE" \
     --single-transaction \
     --source-data=2 \
     --quick \
     --routines \
     --triggers \
     --events \
     --hex-blob \
     --set-gtid-purged=OFF > "$DUMP_FILE"
   test -s "$DUMP_FILE"
   grep -m 1 -E 'CHANGE (MASTER|REPLICATION SOURCE) TO' "$DUMP_FILE"
   ```
5. **[시험 EC2 ec2-user → RDS]** RDS에 복원하고, 복원 성공 여부를 확인한다.
   ```bash
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     < "$DUMP_FILE"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';"
   ```
   복원 명령이 0이 아닌 코드로 끝나거나 테이블 수가 원본과 다르면 중단한다. 원본과 RDS에서 핵심 테이블 행 수, `SHOW CREATE TABLE`, index, trigger, event, routine, charset/collation, `flyway_schema_history`를 비교한다. 비교가 끝날 때까지 애플리케이션 트래픽 전환을 시작하지 않는다.
6. **[시험 EC2 ec2-user → RDS]** 덤프에 기록된 시작 좌표로 RDS 외부 복제를 설정한다.
   ```bash
   export SOURCE_LOG_FILE="$(grep -m 1 -oE "(SOURCE|MASTER)_LOG_FILE='[^']+'" "$DUMP_FILE" | cut -d"'" -f2)"
   export SOURCE_LOG_POS="$(grep -m 1 -oE '(SOURCE|MASTER)_LOG_POS=[0-9]+' "$DUMP_FILE" | cut -d= -f2)"
   test -n "$SOURCE_LOG_FILE" && test -n "$SOURCE_LOG_POS"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e "
   CALL mysql.rds_set_external_source(
     '${EC2_PRIVATE_IP}', 3306, '${REPL_USER}', '${REPL_PASSWORD}',
     '${SOURCE_LOG_FILE}', ${SOURCE_LOG_POS}, 1
   );
   CALL mysql.rds_start_replication;"
   ```
7. **[시험 EC2 ec2-user → RDS]** 복제 상태를 확인한다. 이 단계가 RDS에서 EC2 MySQL로의 실제 네트워크·인증·binlog 연결 검증이다. 다음 조건이 모두 충족된 경우에만 아래의 트래픽 주입과 DB 전환을 진행한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -e 'SHOW REPLICA STATUS\G'
   ```
   `Replica_IO_Running=Yes`, `Replica_SQL_Running=Yes`, `Last_IO_Error`와 `Last_SQL_Error`가 비어 있고, `Seconds_Behind_Source`가 감소하거나 0이어야 한다. 오류가 있거나 source coordinate가 진행하지 않으면 다음 단계로 진행하지 말고 원인부터 해결한다.


### 4. 일정한 트래픽 주입

빈 시험 DB에 위의 시드를 한 번만 넣은 상태에서 시작한다. 시험용 사용자 2001~3000과 그룹 1을 사용한다.
별도 SSH 터미널에서 아래를 실행하고, 실행 중 3번의 데이터 복사·복제와 5번의 전환을 진행한다. 기본값은 초당 1세션(그룹 생성 1회 + 검색 1회), 30분이다.
운영 URL·운영 JWT 키는 사용하지 않는다. `RUN_ID`는 재사용하지 않는다. 반복 시험은 사용자별 그룹 가입 한도 때문에 시드 데이터 재준비가 필요하다.

```bash
cd /opt/app/releases/rehearsal-2.0.0
export RUN_ID="$(openssl rand -hex 5)"
export JWT_SECRET="$(sudo docker inspect springboot --format '{{json .Config.Env}}' |
  python3 -c 'import json,sys; print(next(v.split("=",1)[1] for v in json.load(sys.stdin) if v.startswith("JWT_SECRET=")))')"
sudo install -d -o "$(id -u)" -g "$(id -g)" "results/$RUN_ID"
sudo env JWT_SECRET="$JWT_SECRET" RUN_ID="$RUN_ID" docker run --rm --network host --user "$(id -u):$(id -g)" \
  -e JWT_SECRET -e RUN_ID -e BASE_URL=https://127.0.0.1/api \
  -e RATE=1 -e MINUTES=30 -e SELF_SIGNED=true -e RESULTS_DIR=/results \
  -v "$PWD/loadtest/migration:/scripts:ro" -v "$PWD/results/$RUN_ID:/results" \
  grafana/k6:1.3.0 run --log-format raw \
  --console-output "/results/$RUN_ID-ledger.jsonl" /scripts/traffic.js
unset JWT_SECRET
```

k6 종료 코드가 0이 아니면 성공으로 판정하지 않는다. `RUN_ID`와 결과 파일은 6번에서 사용한다.
자체 서명 인증서 허용은 이 시험용 연결에만 사용한다.

### 5. BE의 DB 연결 대상을 RDS로 전환

3번을 실행한 SSH 세션에서 이어서 실행한다. 각 명령이 성공한 것을 확인한 후 다음 명령을 실행한다.
BE를 재시작하지 않고 관리자 API로 DB 연결 대상을 변경한다. 신규 쓰기는 barrier 해제까지 대기한다.

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

`arm-reverse-replica`로 RDS → EC2 역방향 복제를 시작한 뒤 쓰기를 재개한다.
실패하면 후속 명령을 실행하지 않는다. RDS 승격 전이면 원인 확인 후 `run_migration scripts/mysql-rds-abort.sh`를 실행한다.
승격 후에는 abort를 실행하지 않고 barrier를 유지한 상태에서 담당자가 복구한다.

### 6. 누락·중복 확인과 롤백

트래픽이 정상 종료되고 Kafka consumer 처리가 끝난 뒤 역방향 복제의 IO/SQL이 모두 Yes, 오류 없음, 지연 0인지 확인한다.
지연 0뿐 아니라 최종 RDS binlog 좌표까지 EC2에 적용됐는지 확인하고 그동안 다른 쓰기를 실행하지 않는다.
3번과 같은 세션에서 `RUN_ID`를 4번에서 사용한 값으로 설정하고 두 DB의 시험 데이터를 출력한다.

```bash
export RUN_ID='<4번에서 사용한 RUN_ID>'
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

`passed: true`와 종료 코드 0을 확인한다. 요청 실패·타임아웃, 누락·중복, DB 간 ID 차이가 있으면 실패로 판정한다.
검사 대상은 그룹 생성과 Kafka를 통한 검색 이력이다. 전체 테이블 정합성 비교와 FE·AI·OAuth 시험은 별도로 수행한다.

RDS의 최신 쓰기까지 EC2에 반영됐다고 확인한 경우에만 롤백한다.

```bash
export EC2_REVERSE_REPLICA_READY=yes
run_migration scripts/mysql-rds-rollback.sh
```

BE가 EC2 DB를 사용하는 상태에서 API 읽기·쓰기를 확인한다. 롤백 후 쓰기가 RDS로 자동 복제된다고 가정하지 않는다.
역방향 복제에 지연·오류가 있거나 RDS에 연결할 수 없으면 강제로 EC2로 전환하지 않는다.
리허설 종료 직후 MySQL 컨테이너·데이터 볼륨·migration 상태를 삭제하지 않고, 결과와 담당자의 확인을 남긴다.
