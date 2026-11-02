# EC2 MySQL -> AWS RDS 마이그레이션 가이드

> 애플리케이션 가동 상태를 유지한 채, MySQL의 Binary Log 기반 Replication을 활용하여 RDS로 데이터를 동기화한다.<br>
최종 전환 시에는 짧은 쓰기 대기 구간을 허용하여 데이터 정합성을 확보한다.

### 실행 위치와 고정 경로

이 절차는 **EC2의 `ec2-user` SSH 세션 하나에서 처음부터 끝까지 실행**한다. RDS에는 SSH로 접속하거나
셸 명령을 실행하지 않는다. RDS 관련 `mysql` 명령도 모두 EC2의 `ec2-user` 셸에서 RDS endpoint로
접속하는 방식이다.

스크립트는 EC2의 다음 경로에 설치한다.

```text
/opt/app/releases/migration/scripts/mysql-rds-*.sh
```

`mysql-rds-migration-common.sh`는 다른 스크립트가 자동으로 읽으므로 직접 실행하지 않는다.
Docker socket 권한 때문에 명령은 root 권한으로 실행하지만, 환경변수는 `sudo env`로 명시적으로 전달한다.

마이그레이션 프로파일은 기본 Compose에 넣지 않는다. 다음 override 파일을 기본 파일과
함께 사용한다.

```text
/opt/app/releases/migration/docker-compose.yml
/opt/app/releases/migration/docker-compose.migration.yml
```

```bash
# [EC2 ec2-user] RDS 접속 변수가 준비된 상태에서 migration 프로파일로 WAS를 배포
docker compose \
  -f /opt/app/releases/migration/docker-compose.yml \
  -f /opt/app/releases/migration/docker-compose.migration.yml \
  config --quiet
sudo docker compose \
  -f /opt/app/releases/migration/docker-compose.yml \
  -f /opt/app/releases/migration/docker-compose.migration.yml \
  up -d --force-recreate mysql springboot
```

migration override를 적용하지 않고 기존 MySQL 컨테이너를 재사용하면 384MiB 제한으로
reverse replica 준비 중 OOM이 발생할 수 있다. 반드시 `--force-recreate mysql springboot`
로 컨테이너를 재생성하고 다음 결과가 최소 768MiB인지 확인한다.

호스트 자체의 메모리가 부족하면 MySQL
제한만 올려도 해결되지 않으므로 `free -h`, `docker stats --no-stream`, `dmesg -T |
grep -i oom`으로 확인하고 필요하면 swap을 준비한다.

```bash
sudo docker inspect mysql --format 'memory_limit={{.HostConfig.Memory}}'
# 805306368 이상이어야 한다.
```

일반 운영 배포는 기존처럼 `docker-compose.yml`만 사용한다. migration override를 함께
지정하지 않으면 Spring Boot는 migration 프로파일과 RDS DataSource를 사용하지 않는다.

### 인프라 사전 준비

> 이 절차는 EC2에서 `sudo`, Docker socket, systemd를 사용할 수 있고 `mysql`/`mysqladmin` client가 설치되어 있다는 전제다.<br>
RDS는 기존 v1 EC2 VPC가 아니라 **v2 전용 VPC**에 생성한다. 두 VPC는 VPC peering으로
연결하며, RDS IAM 권한으로 DB 인스턴스와 보안 그룹을 미리 생성하고 애플리케이션의
barrier API가 배포된 상태여야 한다.<br>
`<...>` 표기는 실행 전에 실제 값으로 치환한다.

1. prod와 staging은 서로 다른 VPC와 state에 RDS를 생성한다. dev의 MySQL EC2는 유지한다.
2. 각 환경의 `modules/platform`이 private subnet 두 개를 생성하고 `modules/rds`에 ID를 전달한다. subnet ID를 수동 입력하지 않는다.
3. prod는 기존 피어링을 재사용하고 state 주소 변경은 `moved`로 연결한다. 이미 있는 RDS private CIDR 출발 경로는 import한다. 기존 운영 EC2 subnet ID는 prod `migration.tf`의 local에 고정돼 있다. staging은 시험용 `v1_network`가 있을 때만 마이그레이션 네트워크를 생성한다.
4. v1 EC2 subnet route table에 각 RDS private subnet CIDR을 대상으로 하는 피어링 경로를 추가하고, RDS private route table에는 v1 CIDR 반환 경로를 추가한다.
5. RDS SG는 같은 환경의 BE SG와 피어링 상대 v1 SG에서 TCP 3306을 허용한다. v2 BE의 3306 아웃바운드와 RDS→v1 복제 연결 아웃바운드도 구성한다.
6. 운영 v1 SG 인바운드는 `infra/v1/network.tf`의 개별 rule로 관리한다. 기존 HTTP·HTTPS·SSH rule은 import하고, 기존 v1 RDS와 전용 복제 rule은 제거하며 v2 RDS private CIDR의 TCP 3306 rule을 추가한다. staging 시험용 v1 SG도 inline과 개별 rule을 혼용하지 않도록 소유 설정을 정리한다.
7. RDS는 MySQL 8.4, Multi-AZ, 자동 백업과 삭제 방지를 사용한다.

### VPC peering을 통한 RDS에서 EC2 MySQL로 연결

RDS는 v2 VPC의 private subnet에 있고 EC2는 v1 VPC에 있으므로, RDS가 EC2의 Docker bridge
또는 컨테이너 IP에 직접 연결하지 않는다. VPC peering route를 통해 EC2 사설 IP의 3306으로
접속한다.<br>
EC2 사설 IP의 3306 포트에 `socat`을 systemd 서비스로 열고, 서비스 시작 때마다 현재 컨테이너 IP를 다시 조회한다.

1. EC2에서 다음 값을 설정한다.
   ```bash
   export EC2_PRIVATE_IP='<EC2_PRIVATE_IP>'
   export MYSQL_NETWORK='bakkucca_backend-net'
   export MYSQL_CONTAINER='mysql'
   ```
2. EC2에서 proxy 서비스를 만든다.
   ```bash
   # socat 설치 후 진행('command -v socat', 'rpm -q socat || true'로 확인)
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
   sudo sed -i "s/REPLACE_EC2_PRIVATE_IP/${EC2_PRIVATE_IP}/" /etc/systemd/system/mysql-container-proxy.service
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

### 원본 MySQL Binlog 설정 확인 및 준비

```
SELECT VERSION();

SHOW VARIABLES WHERE Variable_name IN (
  'server_id',
  'log_bin',
  'binlog_format',
  'binlog_row_image',
  'binlog_expire_logs_seconds',
  'gtid_mode'
);

SHOW BINARY LOG STATUS;
```

- 다음 결과가 모두 맞을 때만 진행한다: `VERSION()`이 `8.4.x`, `log_bin=ON`, `server_id`가 0이 아닌 고유값, `binlog_format=ROW`, `binlog_row_image=FULL`.
- `binlog_expire_logs_seconds`는 예상 복원 시간 + 최대 복제 지연 + 24시간 이상이어야 한다. 짧으면 먼저 설정을 늘리고 기존 binlog가 삭제되지 않았는지 확인한다.
- `gtid_mode`가 ON이면 GTID 방식으로 전환할 수 있지만, 이 가이드는 덤프에 기록한 file/position 방식만 사용한다. 실행 중 방식을 섞지 않는다.
- 설정이 맞지 않으면 운영 트래픽 중 `my.cnf`를 변경하지 않는다. 변경 후 MySQL 재시작이 필요하면 별도 점검창에서 수행하고, 재시작 없는 마이그레이션을 진행하지 않는다.
- ```sql
  SELECT @@global.read_only, @@global.super_read_only;
  ```
- RDS와 원본의 문자 집합, collation, time zone, SQL mode 및 주요 schema가 같은지 확인한다.

### 무중단 이관

1. 필요한 값을 한 번만 설정한다.
   ```bash
   # [EC2 ubuntu] /home/ubuntu/bakkucca에서 실행한다.
   set -euo pipefail
   export EC2_PRIVATE_IP="$(hostname -I | awk '{print $1}')"
   export MYSQL_NETWORK='bakkucca_backend-net'
   export MYSQL_DATABASE='market'
   export RDS_HOST="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_URL" {print $2}' | sed -E 's#jdbc:mysql://([^:/]+).*#\1#')"
   export RDS_USER="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_USERNAME" {print $2}')"
   export RDS_PASSWORD="$(sudo docker inspect springboot --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MIGRATION_RDS_DB_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}')"
   export EC2_MYSQL_PASSWORD="$(sudo docker inspect mysql --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '$1=="MYSQL_ROOT_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}')"
   export REPL_USER='repl_user'
   export REPL_PASSWORD="$(openssl rand -base64 32 | tr -dc A-Za-z0-9 | head -c 28)"
   export REVERSE_REPL_USER='reverse_repl'
   export REVERSE_REPL_PASSWORD="$(openssl rand -base64 32 | tr -dc A-Za-z0-9 | head -c 28)"
   export DOCKER_BRIDGE_GATEWAY="$(sudo docker network inspect "$MYSQL_NETWORK" -f '{{(index .IPAM.Config 0).Gateway}}')"
   export DUMP_FILE="/tmp/mysql-migration-${MYSQL_DATABASE}.sql"
   ```
   이 블록은 운영 `.env`를 `source`하지 않고 실행한다. 비밀번호는 명령행에 직접 입력하지 않으며, 이 SSH 세션에서만 환경변수로 유지한다.
2. **[EC2 ubuntu, `prepare-drain` 실행 전 1회만]** 원본 EC2 컨테이너에서 RDS가 접근할 복제 계정을 만든다. Docker bridge를 통과한 RDS 연결은 MySQL에서 `${DOCKER_BRIDGE_GATEWAY}`로 보이므로 이 정확한 IP를 host로 사용한다. RDS가 직접 컨테이너에 연결하는 구조가 아니므로 RDS subnet CIDR를 host 값으로 사용하지 않는다. 이 명령은 EC2 MySQL이 쓰기 가능한 상태일 때만 실행한다. 이미 8번 트래픽 전환까지 완료했다면 이 단계를 다시 실행하지 않는다.
   ```bash
   sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql mysql -uroot -e "
   CREATE USER IF NOT EXISTS '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}' IDENTIFIED BY '${REPL_PASSWORD}';
   ALTER USER '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}' IDENTIFIED BY '${REPL_PASSWORD}';
   GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REPL_USER}'@'${DOCKER_BRIDGE_GATEWAY}';
   FLUSH PRIVILEGES;"
   ```
   검증
   ```
   export MYSQL_PWD="$REPL_PASSWORD"

   mysql \
   --protocol=tcp \
   -h "$EC2_PRIVATE_IP" \
   -P 3306 \
   -u "$REPL_USER" \
   -e "SELECT 1;"
   ```
4. **[EC2 ubuntu → RDS]** RDS에서 rollback용 계정을 만든다. RDS 셸이 아니라 EC2 ubuntu에서 아래 `mysql` 명령을 실행한다. 이 계정은 EC2의 실제 사설 IP만 허용한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e "
   CALL mysql.rds_set_configuration('binlog retention hours', 168);
   CREATE USER IF NOT EXISTS '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}' IDENTIFIED BY '${REVERSE_REPL_PASSWORD}';
   ALTER USER '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}' IDENTIFIED BY '${REVERSE_REPL_PASSWORD}';
   GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}';
   FLUSH PRIVILEGES;
   CALL mysql.rds_show_configuration;"
   ```
   검증
   ```
   export MYSQL_PWD="$REVERSE_REPL_PASSWORD"

   mysql \
   --protocol=tcp \
   -h "$RDS_HOST" \
   -P 3306 \
   -u "$REVERSE_REPL_USER" \
   -e "SELECT 1;"
   ```
5. **[EC2 ubuntu + MySQL container]** 데이터 덤프를 생성한다. 이 명령은 DDL을 동결한 상태에서 실행한다.
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
6. **[EC2 ubuntu → RDS]** RDS에 복원하고, 복원 성공 여부를 확인한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"

   nohup env MYSQL_PWD="$RDS_PASSWORD" \
   mysql --protocol=tcp \
   -h "$RDS_HOST" \
   -u "$RDS_USER" \
   < "$DUMP_FILE" \
   > /tmp/rds-restore.log 2>&1 &

   RESTORE_PID=$!
   echo "$RESTORE_PID" > /tmp/rds-restore.pid
   wait "$RESTORE_PID"

   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';"
   ```
   복원 명령이 0이 아닌 코드로 끝나거나 테이블 수가 원본과 다르면 중단한다. 원본과 RDS에서 핵심 테이블 행 수, `SHOW CREATE TABLE`, index, trigger, event, routine, charset/collation, `flyway_schema_history`를 비교한다. 비교가 끝날 때까지 애플리케이션 트래픽 전환을 시작하지 않는다.
7. **[EC2 ubuntu → RDS]** 덤프에 기록된 시작 좌표로 RDS 외부 복제를 설정한다.
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
8. **[EC2 ubuntu → RDS]** 복제 상태를 확인한다. 이 단계가 RDS에서 EC2 MySQL로의 실제 네트워크·인증·binlog 연결 검증이다. 다음 조건이 모두 충족될 때만 8단계로 이동한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -e 'SHOW REPLICA STATUS\G'
   ```
   `Replica_IO_Running=Yes`, `Replica_SQL_Running=Yes`, `Last_IO_Error`와 `Last_SQL_Error`가 비어 있고, `Seconds_Behind_Source`가 감소하거나 0이어야 한다. 오류가 있거나 source coordinate가 진행하지 않으면 다음 단계로 진행하지 말고 원인부터 해결한다.
9. **[EC2 root via run_migration] 트래픽 전환**
   > RDS의 복제 상태와 데이터 정합성을 확인한 후 진행한다.
   > 전환 중 신규 쓰기는 애플리케이션 barrier에서 대기시키고, 기존 트랜잭션이 끝난 뒤에만 원본을 봉인한다. timeout이나 복제 오류가 발생하면 강제 진행하지 않는다.

   전환 전 체크리스트
    - WAS(Spring Boot)에 모든 인스턴스가 공유하는 `MigrationBarrierManager`가 배포되어 있다.
    - `POST /prepare`, `/commit`, `/health`, `/release`, `/abort` API가 멱등적으로 동작한다.
    - `/prepare`는 새 쓰기를 5xx로 거부하지 않고 barrier 해제까지 대기시킨다.
    - RDS 복제 IO/SQL 스레드가 정상이고 `Last_IO_Error`, `Last_SQL_Error`가 비어 있다.
    - 핵심 테이블 데이터, 스키마, Flyway 상태와 RDS 연결/용량 지표를 검증했다.
    - 전환 실패 시 중단 기준과 담당자를 정했다.
    - `MIGRATION_STATE_DIR`은 모든 단계 스크립트가 접근할 수 있는 동일한 운영 호스트 경로다.

   스크립트는 저장소의 `scripts/`에 단계별 파일로 분리되어 있다. 모든 단계는 같은 환경변수와 상태 디렉터리를 사용하며, 동시에 두 단계가 실행되지 않도록 `flock`을 사용한다.

   공통 환경변수
   ```bash
   export RDS_PORT='3306'
   export EC2_CONTAINER='mysql'
   export WAS_ADMIN_CONTAINER='springboot'
   # 관리자 API가 WAS 컨테이너 내부 localhost만 허용하므로 컨테이너 안에서 호출한다.
   export WAS_ADMIN_URL='http://127.0.0.1:8080/internal/admin/migration'
   export MIGRATION_STATE_DIR='/var/lib/bakkucca/mysql-migration'
   export MIGRATION_TIMEOUT_SECONDS='900'
   export POLL_SECONDS='2'
   ```
   ```bash
   sudo install -d -m 700 "$MIGRATION_STATE_DIR"
   sudo chown root:root "$MIGRATION_STATE_DIR"
   sudo chmod 700 "$MIGRATION_STATE_DIR"
   ```
   EC2의 `ubuntu` 사용자가 Docker socket에 직접 접근할 수 없는 경우가 있으므로,
   아래처럼 root 실행 함수에 필요한 환경변수를 명시적으로 전달한다. EC2의 sudo
   정책에 따라 `sudo -E`가 무시될 수 있으므로 `sudo -E scripts/...` 형식은 사용하지 않는다.
   ```bash
   run_migration() {
     sudo env \
       RDS_HOST="$RDS_HOST" RDS_PORT="$RDS_PORT" \
       RDS_USER="$RDS_USER" RDS_PASSWORD="$RDS_PASSWORD" \
       EC2_MYSQL_PASSWORD="$EC2_MYSQL_PASSWORD" EC2_CONTAINER="$EC2_CONTAINER" \
       WAS_ADMIN_CONTAINER="$WAS_ADMIN_CONTAINER" WAS_ADMIN_URL="$WAS_ADMIN_URL" \
       REVERSE_REPL_USER="$REVERSE_REPL_USER" REVERSE_REPL_PASSWORD="$REVERSE_REPL_PASSWORD" \
       EC2_REVERSE_REPLICA_READY="${EC2_REVERSE_REPLICA_READY:-no}" \
       CONFIRM_FINALIZE="${CONFIRM_FINALIZE:-}" ROLLBACK_TARGET="${ROLLBACK_TARGET:-EC2}" \
       MIGRATION_STATE_DIR="$MIGRATION_STATE_DIR" \
       MIGRATION_TIMEOUT_SECONDS="$MIGRATION_TIMEOUT_SECONDS" POLL_SECONDS="$POLL_SECONDS" \
       "$@"
   }
   ```
   실행 전에 barrier API가 실제로 존재하고 성공 응답을 반환하는지 확인한다. 컨테이너 내부 health endpoint만 정상이어서는 충분하지 않다.
   ```bash
   docker exec "$WAS_ADMIN_CONTAINER" \
     wget -qO- -T 5 --post-data='' \
     "${WAS_ADMIN_URL%/}/health?target=EC2"
   ```
   이 요청이 API가 없는 `404`와 연결 거부는 Spring Boot의 배포 문제로, 트래픽 전환을 실행하지 않는다.

   실행 순서
   ```bash
   set -Eeuo pipefail
   
   cd <scripts 저장 경로>
   test -x ./mysql-rds-validate.sh
   run_migration ./mysql-rds-validate.sh
   run_migration ./mysql-rds-prepare-drain.sh
   run_migration ./mysql-rds-promote.sh
   run_migration ./mysql-rds-arm-reverse-replica.sh
   run_migration ./mysql-rds-switch-traffic.sh
   ```
   `prepare-drain` 또는 `promote` 단계가 실패하면 쓰기 barrier가 유지될 수 있다. RDS 승격 전이면 원인을 확인한 뒤 `../scripts/mysql-rds-abort.sh`를 실행하고, RDS 승격 후에는 abort를 실행하지 말고 현재 barrier 상태를 유지한 채 운영 담당자가 수동으로 복구한다.

    - `mysql-rds-migration-common.sh`: 접속 정보, 잠금, 상태 파일, 복제 상태 및 binlog 좌표 drain 공통 함수. 직접 실행하지 않는다.
    - `mysql-rds-validate.sh`: EC2/RDS 연결, MySQL 8.4, ROW binlog, replica 스레드와 오류 상태를 사전 검증한다.
    - `mysql-rds-prepare-drain.sh`: 애플리케이션 barrier를 획득하고 EC2를 `read_only`/`super_read_only`로 봉인한 뒤 최종 binlog 좌표까지 RDS 적용을 기다린다. 대기 중에는 쓰기를 재개하지 않는다.
    - `mysql-rds-promote.sh`: RDS 외부 복제를 중지·초기화하고 RDS writable 상태를 확인한다. 애플리케이션 barrier는 유지한다.
    - `mysql-rds-arm-reverse-replica.sh`: RDS 승격 직후 RDS binlog 좌표를 기록하고 EC2 reverse replica를 read-only로 기동·검증한다. rollback을 사용하려면 반드시 성공해야 한다.
    - `mysql-rds-switch-traffic.sh`: datasource를 RDS로 바꾸고 실제 RDS 읽기/쓰기 health probe를 통과한 뒤 barrier를 해제한다. 실패하면 barrier를 해제하지 않는다.
    - `mysql-rds-abort.sh`: RDS 승격 전 실패 시 EC2 쓰기를 복구하고 barrier를 해제한다. RDS 승격 후에는 실행하지 않는다.

### 전환 완료 후 현재 DB 사용 위치

`mysql-rds-switch-traffic.sh`가 성공한 뒤에는 애플리케이션의 쓰기 대상이 RDS다.
EC2 MySQL은 RDS의 reverse replica로 유지되므로 다음 상태가 정상이다.

```text
EC2 MySQL: read_only=1, super_read_only=1
RDS:       read_only=0, super_read_only=0
EC2 <- RDS reverse replica: IO=Yes, SQL=Yes
```

따라서 전환 완료 후 EC2 MySQL에서 `CREATE USER`, `ALTER USER`, 애플리케이션 INSERT/UPDATE를
실행하지 않는다. 계정 생성·스키마 변경이 필요하면 RDS에서 수행하고, EC2에는 reverse
replication으로 반영되는 데이터만 기록된다. 전환을 취소하고 EC2를 다시 쓰기 원본으로
사용하려면 임의로 `super_read_only`를 해제하지 말고 [롤백 절차](#장애-발생-시-롤백)를 따른다.

6. 복제 분리 및 단독 인스턴스 승격

   전환 직후 EC2 MySQL을 삭제하거나 볼륨을 폐기하지 않는다.<br>
   업무 피크와 백업 주기 동안 rollback window로 보존한다.<br>
   보존 기간이 끝나고 롤백이 필요 없다고 승인된 뒤 다음을 실행한다.

   ```bash
   export CONFIRM_FINALIZE=yes
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-finalize-legacy.sh
   ```

   `mysql-rds-finalize-legacy.sh`는 EC2 MySQL을 다시 쓰기 가능하게 만들지 않고 `read_only`/`super_read_only`를 유지한 채 restart 정책을 끄고 컨테이너만 정지한다. 데이터 볼륨과 백업은 별도 보존 정책에 따라 유지한다.

### 마이그레이션 완료 후 리소스 정리

정리는 트래픽 전환 직후가 아니라 **rollback 보존 기간이 끝나고 최종 폐기를 승인한 뒤** 수행한다.
정리 작업은 모두 EC2 `ubuntu` 셸에서 실행하며, RDS에 접속할 때도 EC2의 `mysql` client를 사용한다.
RDS 인스턴스 자체, RDS subnet group, parameter group, 암호화·백업 설정은 삭제하지 않는다.

#### 1. 최종 정리 전 확인

다음 조건을 모두 확인한 뒤에만 정리한다.

- 애플리케이션이 RDS를 사용하고 `read_only=0`, `super_read_only=0`이다.
- RDS와 EC2 reverse replica의 최종 데이터 검증 및 RDS 스냅샷/백업 보존이 완료됐다.
- rollback 보존 기간이 끝났고 EC2 복귀가 더 이상 필요 없다는 승인을 받았다.
- EC2 MySQL 컨테이너를 정지해도 애플리케이션 readiness와 실제 API 요청이 정상이다.
- 삭제할 계정, 파일, Docker volume, 보안 그룹 규칙의 대상과 보존 기간을 기록했다.

```bash
# [EC2 ubuntu] RDS가 현재 writable인지 확인
mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
  -e "SELECT @@read_only, @@super_read_only;"

# [EC2 root + MySQL container] reverse replica의 마지막 상태 확인
sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql \
  mysql -uroot -e 'SHOW REPLICA STATUS\G'
```

#### 2. reverse replication 중지

먼저 EC2에서 RDS reverse replica를 중지하고 설정을 제거한다. 이 시점 이후에는 EC2에
RDS 변경사항이 복제되지 않으므로, 이후 EC2 MySQL을 다시 기동해 rollback에 사용하지 않는다.

```bash
# [EC2 root + MySQL container]
sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql mysql -uroot -e \
  'STOP REPLICA; RESET REPLICA ALL;'

# [EC2 ubuntu → RDS] RDS의 rollback 전용 계정 제거
mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e \
  "DROP USER IF EXISTS '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}';"
```

#### 3. 복제·proxy 계정과 listener 정리

reverse replication 중지 후 원본→RDS 초기 복제 계정은 더 이상 사용하지 않는다. 다만 EC2
MySQL은 `super_read_only` 상태가 정상이며, 이 상태에서 `DROP USER`나 계정 변경을 위해
쓰기 보호를 해제하면 안 된다. 계정 제거가 꼭 필요하면 별도 유지보수 승인과 백업을 확보한
후 MySQL 계정 정리 절차를 수행한다. 기본 정리에서는 계정을 남겨 두고 권한·비밀번호를
별도 보안 절차로 폐기하며, EC2 MySQL volume을 폐기할 때 함께 사라지게 한다.

복제 계정 정리 여부와 무관하게, reverse replication과 초기 복제가 모두 끝났으면 RDS에서
EC2로 연결하는 proxy를 중지한다.

```bash
# [EC2 ubuntu]
sudo systemctl disable --now mysql-container-proxy.service
sudo rm -f /usr/local/sbin/mysql-container-proxy.sh
sudo rm -f /etc/systemd/system/mysql-container-proxy.service
sudo systemctl daemon-reload
sudo ss -ltnp | grep ':3306' || true
```

`3306` listener가 사라진 것을 확인한 뒤에만 RDS 보안 그룹의 EC2→EC2 MySQL 접근 규칙을
Terraform에서 제거한다. 변경 후 `terraform plan`에 RDS 인스턴스 교체나 삭제가 표시되면
apply하지 않는다.

#### 4. EC2 MySQL 컨테이너·파일 정리

`mysql-rds-finalize-legacy.sh`를 아직 실행하지 않았다면 먼저 실행한다.

```bash
# [EC2 ubuntu]
export CONFIRM_FINALIZE=yes
run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-finalize-legacy.sh
```

컨테이너가 정지된 것을 확인한 후, 보존 정책에 따라 둘 중 하나만 선택한다.

```bash
# [EC2 root] 컨테이너만 제거하고 volume은 보존하는 기본 선택
sudo docker rm mysql

# [EC2 root] 최종 승인과 별도 백업 확인 후에만 volume까지 삭제
sudo docker volume rm bakkucca_mysql-data
```

volume 삭제는 되돌릴 수 없으므로 rollback 보존 기간, RDS 백업, 별도 dump 보존을 확인하기
전에는 실행하지 않는다. `lucid_tesla`처럼 마이그레이션 대상이 아닌 컨테이너는 이 절차에서
삭제하지 않는다.

#### 5. 임시 산출물·상태 파일 정리

비밀번호가 포함될 수 있는 dump, 임시 secret, migration 상태 파일은 보존 필요성을 확인한
뒤 EC2에서 삭제한다. RDS endpoint와 계정 비밀번호가 shell history나 별도 로그에 남아 있으면
비밀번호를 교체한다.

```bash
# [EC2 ubuntu]
rm -f "$DUMP_FILE"
unset RDS_PASSWORD EC2_MYSQL_PASSWORD REPL_PASSWORD REVERSE_REPL_PASSWORD MYSQL_PWD

# [EC2 root]
sudo rm -rf /tmp/bakkucca-migration-secrets /tmp/bakkucca-migration-state
sudo rm -rf /var/lib/bakkucca/mysql-migration
```

`/home/ubuntu/bakkucca/scripts/`의 migration 스크립트는 다음 마이그레이션에 사용할 수
있으므로 보존하거나 릴리스 관리 절차로 제거한다. 현재 운영 Compose에 포함된 스크립트라면
임의로 삭제하지 않는다.

#### 6. Terraform 정리 원칙

Terraform으로 생성한 RDS 리소스는 운영 리소스이므로 제거 대상이 아니다.

- 유지: `aws_db_instance.mysql`, RDS subnet group, MySQL 8.4 parameter group, RDS security group
- 마이그레이션 종료 후 검토: EC2에 대한 RDS→EC2 3306 ingress 규칙, migration 전용 listener/proxy
- 별도 승인 없이는 제거 금지: EC2 instance, EIP, 기존 MySQL volume, RDS final snapshot/backup

보안 그룹 규칙을 제거할 때는 Terraform 코드에서 해당 리소스를 수정한 뒤 다음을 확인한다.

```bash
# [EC2가 아닌 Terraform 실행 환경]
cd /path/to/KTB4-1st-CLOUD/infra/v1
terraform fmt
terraform validate
terraform plan
```

plan에 `aws_db_instance.mysql`의 `destroy`, `-/+ replacement` 또는 RDS subnet group
삭제가 포함되면 정리 작업을 중단한다.

### 장애 발생 시 롤백

롤백은 RDS의 최신 쓰기를 EC2 reverse replica에 반영하고 있음을 별도로 확인한 경우에만 수행한다.<br>
복제 지연이나 오류가 있으면 대기하거나 수동 대응하며, 잔여 복제를 무시하고 진행하지 않는다.

```bash
export EC2_REVERSE_REPLICA_READY=yes
run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-rollback.sh
```

`mysql-rds-rollback.sh`
- 애플리케이션 barrier를 획득하고 보존된 EC2 컨테이너를 기동한 뒤 reverse replica의 IO/SQL 스레드와 오류 상태를 확인한다.
- 확인 후에만 EC2 쓰기를 열고 `commit -> health -> release` 순서로 복귀한다.
- RDS가 응답하지 않거나 reverse replica가 검증되지 않은 경우에는 트래픽을 강제로 전환하지 않는다.
- 각 단계가 실패하면 barrier가 유지되므로 원인 확인 후 `/abort?target=EC2`를 호출하고 수동으로 상태를 복구한다.

### 문제 발생 시 점검

이 절은 정상 실행 순서가 실패했을 때만 확인한다.

- `Replica_IO_Running: Connecting`과 `Last_IO_Errno: 1045`가 함께 보이면 MySQL 계정 host가
  Docker bridge gateway와 일치하는지 확인한다.
  ```bash
  sudo docker network inspect bakkucca_backend-net -f '{{(index .IPAM.Config 0).Gateway}}'
  sudo docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" mysql mysql -uroot -e \
    "SELECT User, Host FROM mysql.user WHERE User='repl_user';"
  ```
  계정 host는 위 gateway IP여야 한다. 수정 후 EC2 ubuntu에서 RDS에 접속해 다음을 실행한다.
  ```bash
  mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e \
    'CALL mysql.rds_stop_replication; CALL mysql.rds_start_replication; SHOW REPLICA STATUS\G'
  ```
- `Last_IO_Errno`가 `2002`, `2003`, `2005`이면 계정 문제가 아니라 EC2 보안 그룹,
  `socat` listener, 라우팅 또는 DNS를 점검한다.
- drain이 timeout되면 RDS의 `Relay_Source_Log_File`과 `Exec_Source_Log_Pos`를 확인한다.
  MySQL 8.4에서는 `Exec_Source_Log_File` 대신 `Relay_Source_Log_File`이 표시될 수 있다.
- EC2 reverse replica의 SQL 오류가 `mysql.rds_heartbeat2` 같은 RDS 내부 테이블이면
  reverse replica 스크립트를 최신 버전으로 교체한 뒤 다시 실행한다. RDS 관리용 내부
  테이블은 애플리케이션 데이터가 아니므로 `mysql.rds_%` 필터로 제외해야 한다.
- 관리자 API가 `403`이면 EC2 ubuntu에서 컨테이너 IP로 호출하지 말고 반드시 스크립트를
  사용한다. 스크립트가 `sudo docker exec springboot`로 컨테이너 내부 localhost를 호출한다.
- `prepare` 이후 스크립트가 중단되면 EC2 쓰기와 barrier가 유지될 수 있다. RDS 승격 전에는
  다음 명령으로만 중단 상태를 복구한다.
  ```bash
  run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-abort.sh
  ```
  RDS 승격 후에는 `abort`를 실행하지 말고 reverse replica 검증 후 rollback 절차를 사용한다.
