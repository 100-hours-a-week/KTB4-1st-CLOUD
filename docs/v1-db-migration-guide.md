# 개요

목표: v2로 DB 아키텍처를 전환하며 현재 운영 중인 서비스에 영향을 최소화하고, 사용자 경험을 해치지 않도록 **무중단 마이그레이션**을 진행한다.

## v1(기존)

> 단일 EC2 인스턴스(모든 운영 컨테이너 공존) 내부 컨테이너(MySQL) + EBS 볼륨<br>

### 기존 구조의 문제점

- 단일 장애점(SPOF) 및 무중단 운영 불가
    - WAS, MySQL, MongoDB, Redis가 단일 OS 커널과 호스트 자원을 공유한다.
    - OOM Killer, 커널 패닉, 인스턴스 장애 발생 시 서비스 전체가 중단될 수 있다.
    - 정기 배포 및 DB 유지보수 시 다운타임이 불가피하다.
- 단일 EBS 디스크 I/O 경합 및 처리량 병목
    - MySQL, MongoDB, Redis, 애플리케이션 로그가 단일 EBS(gp2/gp3) 볼륨의 IOPS와 대역폭을 공유한다.
    - 특정 데이터베이스의 쓰기 트래픽이 증가하면 디스크 I/O 경합으로 인해 핵심 거래/인증 관련 MySQL 트랜잭션까지 Commit 지연 및 Lock Timeout 에러를 유발한다.
- 비현실적인 메모리 설정에 따른 Buffer Pool 잠식
    - 기존 buffer-pool-size=128M는 활성 데이터셋(Working Set)을 유지하기에 부족하다.
    - 대량의 채팅 텍스트가 MySQL에 저장될 경우 인덱스 B-Tree 분할과 함께 유저/물품 엔티티 캐시를 지속적으로 밀어내는 버퍼 풀 오염(Buffer Pool Churn)이 발생한다.
- 커넥션 고갈 위험
    - max-connections=30 설정은 향후 WAS 다중화 환경을 감당하지 못해, 피크 트래픽 발생 시 커넥션 획득 실패 및 요청 지연을 야기한다.
- 재해 복구 및 백업의 신뢰성 부재
    - 스케줄러 기반의 수동 덤프 방식은 백업 실행 시 순간적인 락 경합을 유발한다.
    - 장애 발생 시 특정 시점 복구(PITR)가 불가능하여 직전 트랜잭션 유실 위험이 크다.

<br>

## v2(목표)

> RDS Multi-AZ MySQL + MongoDB Atlas

### 개선 사항

- 스토리지 및 I/O 물리 격리
    - RDBMS(거래/유저)와 NoSQL(채팅), 캐시(세션/웹소켓)를 물리적으로 분리된 인프라로 격리하여 디스크 I/O 경합을 차단한다.
    - MySQL 전용 gp3 볼륨(기본 3,000 IOPS, 125 MB/s)을 통해 트랜잭션 지연을 1~2ms 수준으로 안정화한다.
- RDS Multi-AZ 동기식 복제를 통한 고가용성(HA) 확보
    - 주 인스턴스(Primary) 장애 발생 시 관리자의 수동 개입 없이 60초 이내에 예비 인스턴스(Standby)로 DNS 기반 자동 장애 조치(Auto-Failover)가 완료되어 단일 장애점을 제거한다.
- 버퍼 풀 Hit Ratio 극대화 및 도메인 집중
    - 가변 길이 텍스트 기반의 고빈도 쓰기(Append-only) 작업인 채팅 데이터를 MongoDB로 이전함으로써, MySQL Buffer Pool(2.8GB)을 핵심 도메인(trade, item, user)
      의 인덱스 및 데이터 페이지 캐싱에 온전히 집중시켜 99% 이상의 메모리 적중률을 유지한다.
- HikariCP와 연계된 안전 커넥션 풀 확보
    - max_connections를 100으로 증설한다.
    - 무중단 롤링 배포 시 구/신버전 WAS 컨테이너가 공존하는 오버랩 구간(최대 40개 커넥션)과 AWS RDS 백그라운드 헬스체크 데몬 슬롯을 안전하게 수용한다.
- 관리형 백업 체계(PITR) 도입
    - AWS RDS의 지속적 트랜잭션 로그 백업을 통해 원하는 특정 시점(초 단위)으로 즉시 인스턴스를 복원할 수 있는 복구 체계를 구축한다.
- DB 시스템 운영 공수 최소화
    - 복잡한 Replica Set 구성, 엔진 버전 마이너 패치, 스토리지 자동 확장을 클라우드 관리형 서비스에 위임하여 핵심 비즈니스 개발에 집중한다.
    - 인프라 운영 부담을 줄이되, 모니터링/복구/보안 설정은 별도로 검증한다.

<details>
<summary> MongoDB Replica Set 도입 이유  </summary>

### 동작 원리

1. 데이터 복제
    - 클라이언트의 모든 쓰기 요청은 Primary 노드에서만 처리된다.
    - Primary는 데이터 변경 내역을 Operations Log(oplog)에 기록한다.
    - Secondary 노드들은 oplog를 실시간으로 로컬에 비동기 replay하여 데이터 정합성을 유지한다.
2. Heartbeat
    - 클러스터의 모든 노드는 2초마다 서로에게 하트비트 패킷을 전송하여 생존 여부를 모니터링한다.
3. Primary 노드 자동 선출 및 장애 복구
    - 10초 이내에 Primary의 하트비트 응답이 없으면, Secondary 노드들이 선출 알고리즘을 가동한다.
    - 과반수(노드가 3개면 2개 이상)의 투표를 얻은 가장 최신 oplog를 가진 Secondary가 새로운 Primary로 자동 승격된다.

### 사용 이유

- 단일 인스턴스 장애 시 관리자 개입이나 수동 복구 스크립트 없이 5초 이내에 애플리케이션 드라이버가 새 Primary를 감지하여 연결하므로 채팅 서비스 다운타임을 최소화한다.
- 중요 데이터 저장 시 `w: "majority` 옵션을 적용하면 과반수의 Secondary 노드에 oplog 기록 완료 후 커밋 응답을 반환하므로, Primary 노드 크래시 발생 시 데이터 롤백을 방지한다.
- Rolling Update 방식으로 Secondary 노드를 하나씩 패치/업그레이드 후 마지막에 Primary를 안전하게 전환할 수 있어 점검 중에도 서비스를 무중단으로 운영할 수 있다.

</details>

<details>

<summary> MongoDB Atlas vs 직접 EC2 인스턴스에 replica set 구축 </summary>

> 현재 팀 내에 전담할 DBA가 없고, 현재 급하게 성장 중인 서비스라 고가용성이 매우 중요하다.<br>
> 따라서 약 20$/월 비용 지출을 감수하고 관리형 서비스를 이용한다.

 비교 항목            | MongoDB Atlas (완전 관리형)                            | 직접 EC2에 Replica Set 구축 (Self-Hosted)
------------------|---------------------------------------------------|-------------------------------------------------------
 설치 및 초기 구성       | 클릭 몇 번으로 클러스터 생성                                  | OS 설치, MongoDB 패키지 설치, 키파일/인증 설정, rs.initiate() 수동 구성
 백업 및 복구          | 자동 백업 및 시점 복구(PITR) 기본 제공                         | 스크립트 작성, S3 연동 및 복구 절차 직접 구현 필요
 패치 및 업그레이드       | 벤더가 무중단/정기 패치 및 버전 업그레이드 관리                       | OS 보안 패치, MongoDB 버전 업그레이드를 직접 테스트하고 수행
 고가용성(HA) 및 장애 극복 | Primary 장애 시 자동 페일오버 및 노드 교체                      | 하트비트 감시, 장애 감지 및 수동/스크립트 기반 조치 구성 필요
 비용 (인프라 대비)      | 약 57.6$                                           | 약 35$~40$ (t4g.small 2대 + t4g.nano 1대)
 운영 리소스 (인건비)     | 최소한의 관리만 필요                                       | DB 유지보수, 장애 대응, 모니터링을 위한 전담 엔지니어 시간 소모
 보안 및 규정 준수       | 암호화(AES-256), PrivateLink, SOC 2/HIPAA 등 기본 인증 확보 | 보안 그룹, VPC, 디스크 암호화 등을 직접 설정 및 감사(Audit) 대응

</details>

<br>

## 마이그레이션 핵심 원칙

- Zero-Downtime
    - 마이그레이션 실행 중에도 사용자의 읽기/쓰기 요청을 100% 정상 수용하며 전환한다.
- Failure Isolation
    - 신규 인프라 검증과 데이터 복제 중 문제가 발생해도 기존 MySQL을 운영 원본으로 유지한다.
    - 전환 승인 전까지 애플리케이션의 쓰기 대상은 기존 MySQL로 유지한다.
- Instant Rollback
    - 전환 직후 예기치 못한 병목이나 데이터 불일치가 발생할 경우, 1분 이내에 이전 인프라 상태로 복귀할 수 있는 롤백 경로를 유지한다.
    - RDS에 쓰기가 발생한 이후에는 DB URL만 원복하면 신규 데이터가 유실될 수 있으므로, 롤백 가능 조건을 명확히 정의한다.

<br>

---
<br>

# 무중단 마이그레이션 아키텍처 및 실행 계획

- RDS MySQL 이관을 먼저 성공적으로 완료한 뒤, 채팅 데이터 MongoDB 분리를 별도로 진행한다.
    - 인프라 물리 이관(동종 DB 동일 버전)과 이종 DB 및 비즈니스 로직 수정을 동시 진행하면 실패 원인 격리가 불가하다.

## DB 전환을 위한 설정

<details>
<summary> ProxySQL은 사용하지 않는다. </summary>

ProxySQL: 애플리케이션과 DB 서버 사이에서 요청을 중계하고 관리한다.

- 애플리케이션이 보내는 SQL 쿼리를 분석하여 쓰기 작업은 Primary DB로, 읽기 작업은 Secondary DB로 자동 분류하여 전달한다.
- 읽기 전용 쿼리를 여러 Secondary DB에 분산 처리하여 DB 전체 부하를 줄인다.
- 애플리케이션과 DB 간의 커넥션을 효율적으로 관리하여 네트워크 리소스를 최적화하고 DB 서버의 연결 과부하를 방지한다.
- Primary 또는 Secondary 서버에 장애가 발생하면, 이를 감지하여 비정상 노드를 트래픽 대상에서 자동 제외한다.
- 자주 조회되는 쿼리 결과를 메모리에 캐시하거나, 성능 향상을 위해 특정 쿼리를 동적으로 수정할 수 있다.

현재 v2 설계에서는 읽기 분산을 하지 않는다.<br>
일회성 DB 마이그레이션을 위해 별도 미들웨어를 도입하면 컨테이너 운영, 포트 바인딩, 라우팅 설정 및 장애 대응 복잡도가 증가한다.<br>
결론적으로 ProxySQL의 기능을 대부분 사용하지 않고, DB 연결 경로를 바꾸는 용도로만 활용하는 것은 리소스 비용에 비하면 적절치 못하다.
</details>

<details>
<summary> `AbstractRoutingDataSource`를 활용한다. </summary>

- Spring Boot 내부에서 DB 연결 대상을 선택한다.
- 기존 WAS 컨테이너를 재시작하지 않고 DB 연결 대상을 전환할 수 있다.
- LazyConnectionDataSourceProxy를 활용해 실제 SQL 실행 시점까지 커넥션 획득을 지연한다.
- ReentrantReadWriteLock 기반의 쓰기 배리어를 사용해 기존 트랜잭션을 종료한 뒤 라우팅 대상을 전환한다.

단, 라우팅 대상을 변경하는 것만으로 이미 획득한 커넥션이 다른 DB로 이동하지는 않는다.<br>
따라서 모든 DB 트랜잭션이 동일한 배리어 정책을 따르도록 구성해야 한다. HTTP 요청뿐 아니라 스케줄러, 비동기 작업, 배치 작업 등 DB를 사용하는 모든 실행 경로가 포함되어야 한다.<br>
락은 하나의 JVM 내부에서만 유효하므로, WAS가 한 대라는 현재 전제와 모든 DB 접근이 동일한 락을 사용한다는 전제가 유지되어야 한다.<br>
관리자 API는 전환 상태를 검증하고 쓰기 배리어를 제어하는 용도로 사용한다. 전환이 시간은 실제 부하 테스트로 측정한다.
</details>

### Transaction Drain & Write Barrier

<details>
<summary> 정합성 문제가 발생하는 예시 </summary>

1. Transaction A가 EC2 MySQL에서 결제/게시글 작성 시작.
2. 그 순간 라우팅 스위치가 켜져 타깃이 RDS로 전환.
3. 2ms 뒤 들어온 Transaction B가 RDS 조회.
4. Transaction A의 데이터가 아직 RDS로 Binlog 복제(수십 ms 소요)되지 않아 Transaction B는 최신 데이터를 조회할 수 없다(정합성 파괴).

</details>

**`ReentrantReadWriteLock`** <br>
일반적인 DB 접근 경로는 ReadLock을 획득하고, DB 전환 작업은 WriteLock을 획득하도록 설계한다.

1. 일반 DB 작업은 트랜잭션 전체 실행 구간에서 ReadLock을 유지한다.
2. 마이그레이션 작업이 WriteLock을 요청한다.
3. 신규 DB 작업은 배리어에서 대기한다.
4. 기존 작업이 커밋 또는 롤백을 완료하고 ReadLock을 반환할 때까지 대기한다.
5. 진행 중인 DB 작업이 없음을 확인한다.
6. EC2 → RDS 복제의 최종 적용 상태를 확인한다.
7. 라우팅 타깃을 RDS로 교체한다.
8. WriteLock을 해제하고 신규 작업을 허용한다.

**주의사항**

- 락은 Spring 트랜잭션이 시작되기 전에 획득하고, 트랜잭션 완료 후 반환해야 한다.
- 락의 획득·해제 범위와 @Transactional의 경계가 일치하도록 AOP 실행 순서를 명시적으로 구성한다.
- DB 작업이 끝나기 전에 락을 반환하지 않는다.
- 쓰기 배리어 대기 시간에 제한을 둔다. 제한 시간 초과 시 DB 타깃을 변경하지 않고 전환을 중단한다.
- 대기 중인 요청이 ThreadPool을 고갈시키지 않도록 요청 대기열, 타임아웃 및 재시도 정책을 구성한다.
- 쓰기 배리어는 신규 쓰기 요청을 무한정 쌓아 두는 장치가 아니다. 제한 시간을 초과한 요청은 명확한 오류 응답 또는 재시도 가능한 응답으로 처리한다.
- 단일 WAS에서 동작하는 스케줄러, 비동기 작업 및 운영 작업도 같은 배리어를 준수해야 한다.

**`LazyConnectionDataSourceProxy`**

- `JpaTransactionManager`와 `DataSource` 조합에서는 트랜잭션 시작 시점과 실제 JDBC 커넥션 획득 시점이 다를 수 있다.
- `LazyConnectionDataSourceProxy`를 라우팅 `DataSource` 앞에 배치하여 실제 SQL 실행 시점까지 커넥션 획득을 지연한다.
- `LazyConnectionDataSourceProxy`는 커넥션 획득을 지연할 뿐, 트랜잭션 중간의 라우팅 변경이나 데이터 정합성을 자동으로 보장하지 않는다.

**Flyway 스키마 정합성 보장**

- 덤프 및 복원 과정에서 flyway_schema_history가 RDS로 복원되는지 확인한다.
- 전환 전 EC2와 RDS의 스키마 버전이 동일한지 검증한다.
- 마이그레이션 기간에는 스키마 변경을 동결한다.
- 다중 DataSource 환경에서는 Spring Boot의 Flyway 자동 구성이 의도한 DB를 대상으로 하는지 확인한다.
- Flyway가 EC2와 RDS 양쪽에 의도치 않게 DDL을 실행하지 않도록 대상 DataSource를 명시적으로 관리한다.
- 전환 이후 Flyway의 대상 DB가 RDS로 지정되어 있는지 확인한다.

## EC2 MySQL -> AWS RDS 무중단 이관

> 애플리케이션 가동 상태를 유지한 채, MySQL의 Binary Log 기반 Replication을 활용하여 RDS로 데이터를 동기화한다.<br>
  최종 전환 시에는 짧은 쓰기 대기 구간을 허용하여 데이터 정합성을 확보한다.

### 실행 위치와 고정 경로

이 절차는 **EC2의 `ubuntu` SSH 세션 하나에서 처음부터 끝까지 실행**한다. RDS에는 SSH로 접속하거나
셸 명령을 실행하지 않는다. RDS 관련 `mysql` 명령도 모두 EC2의 `ubuntu` 셸에서 RDS endpoint로
접속하는 방식이다.

| 표시 | 실행 위치 | 사용 방법 |
|---|---|---|
| `EC2 ubuntu` | EC2 호스트의 `/home/ubuntu/bakkucca` | SSH로 접속한 기본 `ubuntu` 셸 |
| `EC2 root` | 같은 EC2 호스트 | `sudo env ... /home/ubuntu/bakkucca/scripts/<script>` |
| `MySQL container` | EC2의 `mysql` 컨테이너 | `sudo docker exec mysql ...` |
| `WAS container` | EC2의 `springboot` 컨테이너 | migration 스크립트가 `sudo docker exec springboot ...`로 호출 |
| `RDS` | 별도 셸 없음 | `EC2 ubuntu`에서 `mysql -h "$RDS_HOST"`로 접속 |

```bash
# EC2 ubuntu에서 실행
ssh -i /Users/janna/Downloads/bakkucca-v1-janna.pem ubuntu@3.34.49.8
cd /home/ubuntu/bakkucca
```

스크립트는 EC2의 다음 경로에 설치한다.

```text
/home/ubuntu/bakkucca/scripts/mysql-rds-*.sh
```

`mysql-rds-migration-common.sh`는 다른 스크립트가 자동으로 읽으므로 직접 실행하지 않는다.
Docker socket 권한 때문에 명령은 root 권한으로 실행하지만, 환경변수는 `sudo env`로 명시적으로 전달한다.

마이그레이션 프로파일은 기본 Compose에 넣지 않는다. 다음 override 파일을 기본 파일과
함께 사용한다.

```text
/home/ubuntu/bakkucca/docker-compose.yml
/home/ubuntu/bakkucca/docker-compose.migration.yml
```

```bash
# [EC2 ubuntu] RDS 접속 변수가 준비된 상태에서 migration 프로파일로 WAS를 배포
docker compose \
  -f /home/ubuntu/bakkucca/docker-compose.yml \
  -f /home/ubuntu/bakkucca/docker-compose.migration.yml \
  config --quiet
sudo docker compose \
  -f /home/ubuntu/bakkucca/docker-compose.yml \
  -f /home/ubuntu/bakkucca/docker-compose.migration.yml \
  up -d springboot
```

일반 운영 배포는 기존처럼 `docker-compose.yml`만 사용한다. migration override를 함께
지정하지 않으면 Spring Boot는 migration 프로파일과 RDS DataSource를 사용하지 않는다.

### 인프라 사전 준비

> 이 절차는 EC2에서 `sudo`, Docker socket, systemd를 사용할 수 있고 `mysql`/`mysqladmin` client가 설치되어 있다는 전제다.<br>
  RDS IAM 권한으로 DB 인스턴스와 보안 그룹을 미리 생성하고, 애플리케이션의 barrier API가 배포된 상태여야 한다.<br>
  `<...>` 표기는 실행 전에 실제 값으로 치환한다.

1. EC2 VPC ID, 사설 IP 확인
2. DB 서브넷 그룹 생성(EC2와 동일한 VPC)
3. 보안 그룹 상호 참조 인바운드 설정
    - EC2 보안 그룹
        - 프로토콜: TCP
        - 포트 범위: 3306
        - 소스: RDS 보안 그룹
    - RDS 보안 그룹
        - 프로토콜: TCP
        - 포트 범위: 3306
        - 소스: EC2 보안 그룹
    - 네트워크 ACL 및 라우팅 테이블이 연결을 차단하지 않는지 확인한다.
4. RDS
    - Multi-AZ 배포와 자동 백업 활성화
    - MySQL 엔진 버전 8.4로 고정

### RDS에서 EC2 MySQL로 연결

RDS는 Docker bridge의 컨테이너 IP에 직접 연결하지 않는다.<br>
EC2 사설 IP의 3306 포트에 `socat`을 systemd 서비스로 열고, 서비스 시작 때마다 현재 컨테이너 IP를 다시 조회한다.

1. EC2에서 다음 값을 설정한다.
   ```bash
   export EC2_PRIVATE_IP='<EC2_PRIVATE_IP>'
   export MYSQL_NETWORK='bakkucca_backend-net'
   export MYSQL_CONTAINER='mysql'
   ```
2. EC2에서 proxy 서비스를 만든다.
   ```bash
   # Ubuntu EC2 기준
   sudo apt-get update
   sudo apt-get install -y socat
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
   EC2 내부 확인이 실패하면 다음 단계로 진행하지 않는다.    EC2 보안 그룹은 RDS 보안 그룹에서만 3306을 허용한다.<br>
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
3. **[EC2 ubuntu → RDS]** RDS에서 rollback용 계정을 만든다. RDS 셸이 아니라 EC2 ubuntu에서 아래 `mysql` 명령을 실행한다. 이 계정은 EC2의 실제 사설 IP만 허용한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" -e "
   CALL mysql.rds_set_configuration('binlog retention hours', 168);
   CREATE USER IF NOT EXISTS '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}' IDENTIFIED BY '${REVERSE_REPL_PASSWORD}';
   GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${REVERSE_REPL_USER}'@'${EC2_PRIVATE_IP}';
   FLUSH PRIVILEGES;
   CALL mysql.rds_show_configuration;"
   ```
4. **[EC2 ubuntu + MySQL container]** 데이터 덤프를 생성한다. 이 명령은 DDL을 동결한 상태에서 실행한다.
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
5. **[EC2 ubuntu → RDS]** RDS에 복원하고, 복원 성공 여부를 확인한다.
   ```bash
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     < "$DUMP_FILE"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';"
   ```
   복원 명령이 0이 아닌 코드로 끝나거나 테이블 수가 원본과 다르면 중단한다. 원본과 RDS에서 핵심 테이블 행 수, `SHOW CREATE TABLE`, index, trigger, event, routine, charset/collation, `flyway_schema_history`를 비교한다. 비교가 끝날 때까지 애플리케이션 트래픽 전환을 시작하지 않는다.
6. **[EC2 ubuntu → RDS]** 덤프에 기록된 시작 좌표로 RDS 외부 복제를 설정한다.
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
7. **[EC2 ubuntu → RDS]** 복제 상태를 확인한다. 이 단계가 RDS에서 EC2 MySQL로의 실제 네트워크·인증·binlog 연결 검증이다. 다음 조건이 모두 충족될 때만 8단계로 이동한다.
   ```bash
   export MYSQL_PWD="$RDS_PASSWORD"
   mysql --protocol=tcp -h "$RDS_HOST" -u "$RDS_USER" \
     -e 'SHOW REPLICA STATUS\G'
   ```
   `Replica_IO_Running=Yes`, `Replica_SQL_Running=Yes`, `Last_IO_Error`와 `Last_SQL_Error`가 비어 있고, `Seconds_Behind_Source`가 감소하거나 0이어야 한다. 오류가 있거나 source coordinate가 진행하지 않으면 다음 단계로 진행하지 말고 원인부터 해결한다.
8. **[EC2 root via run_migration] 트래픽 전환**
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
   export RDS_HOST='<RDS_ENDPOINT>'
   export RDS_PORT='3306'
   export RDS_USER='<RDS_ADMIN_USER>'
   export RDS_PASSWORD='<RDS_ADMIN_PASSWORD>'
   export EC2_MYSQL_PASSWORD='<EC2_MYSQL_ROOT_PASSWORD>'
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
     "${WAS_ADMIN_URL%/}/health?target=RDS"
   ```
   이 요청이 `404`, 연결 거부 또는 인증 오류이면 트래픽 전환을 실행하지 않는다. `health`는 아직 `commit`하지 않은 상태에서는 `409`를 반환할 수 있으므로, 이 경우 API가 존재하고 접근 가능한 것으로 보고 다음 단계로 진행한다. API가 없는 `404`와 연결 거부는 Spring Boot 레포의 배포 문제다.

   실행 순서
   ```bash
   cd /home/ubuntu/bakkucca
   test -x /home/ubuntu/bakkucca/scripts/mysql-rds-validate.sh
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-validate.sh
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-prepare-drain.sh
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-promote.sh
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-arm-reverse-replica.sh
   run_migration /home/ubuntu/bakkucca/scripts/mysql-rds-switch-traffic.sh
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

## MySQL 채팅 데이터 -> MongoDB Atlas 무중단 분리

이 절차는 MySQL의 채팅 데이터를 MongoDB Atlas로 옮기는 별도 마이그레이션이다. MySQL→RDS 전환과 동시에 수행하지 않는다. Atlas로 읽기를 전환한 뒤에도 MySQL 원본과 변경 이력을 rollback window 동안 보존한다.

### 목표와 절대 조건

- 메시지의 `message_id`는 두 저장소에서 동일한 불변 ID를 사용한다. MongoDB `_id`로 사용하면 중복 백필과 재시도가 안전하다.
- 정렬 기준은 DB 삽입 시각이 아니라 `conversation_id`별 단조 증가 `sequence` 또는 `(created_at, message_id)`로 고정한다. 모든 조회 API가 동일한 기준을 사용한다.
- 이중 쓰기 실패를 무시하거나 “MongoDB 저장 성공처럼” 응답하지 않는다. MongoDB 반영이 확인되지 않은 쓰기는 재시도 가능한 상태로 기록한다.
- 메시지의 생성/수정/삭제는 멱등적이어야 한다. 동일 `message_id` 재처리는 결과가 한 번 반영된 것과 같아야 한다.
- 백필은 운영 원본인 MySQL에서 수행하고, 운영 트래픽의 읽기는 전환 전까지 MySQL에서 계속 제공한다.
- MongoDB 읽기 전환은 카나리와 정합성 검증 후 수행한다. 검증 실패 시 읽기 대상을 즉시 MySQL로 되돌릴 수 있어야 한다.

### 데이터 모델과 인덱스

MongoDB Atlas에 애플리케이션 전용 database와 collection을 만든다. 실제 MySQL 테이블/컬럼명은 구현 전에 확정하고, 개인정보·파일 본문 등 채팅 메시지에 필요 없는 컬럼은 복사하지 않는다.

```json
{
  "_id": "message_id",
  "conversation_id": "conversation_id",
  "sequence": 12345,
  "sender_id": "user_id",
  "body": "message body",
  "created_at": "2026-10-18T13:00:00Z",
  "updated_at": "2026-10-18T13:00:00Z",
  "deleted_at": null,
  "schema_version": 1
}
```

필수 인덱스는 다음과 같다. `conversation_id`와 정렬 필드의 방향은 실제 조회 쿼리와 일치시킨다.

```javascript
db.messages.createIndex(
  { conversation_id: 1, sequence: 1, _id: 1 },
  { name: "conversation_sequence" }
)
db.messages.createIndex(
  { conversation_id: 1, created_at: 1, _id: 1 },
  { name: "conversation_created_at" }
)
db.messages.createIndex(
  { updated_at: 1, _id: 1 },
  { name: "migration_reconciliation" }
)
```

TTL index는 사용하지 않는다. 보존 기간이 필요한 경우 애플리케이션 정책과 명시적인 삭제 이벤트로 관리한다.

### Atlas 사전 준비

1. Atlas 프로젝트와 Production cluster를 생성한다. 리전은 애플리케이션/RDS와 지연이 낮은 리전으로 선택하고, 자동 백업과 point-in-time 복구를 활성화한다.
2. Atlas Network Access에서 EC2/WAS의 egress 경로만 허용한다. 테스트용 `0.0.0.0/0`을 운영에 사용하지 않는다. VPC peering 또는 PrivateLink를 사용할 경우 DNS와 라우팅까지 확인한다.
3. 애플리케이션 전용 database user를 만든다. 운영 애플리케이션에는 collection에 필요한 `readWrite`만 부여하고 cluster 관리자 계정을 사용하지 않는다.
4. 연결 문자열과 비밀번호는 Secret Manager에서 주입한다. URI를 문서, 이미지, 로그, 명령행에 평문으로 남기지 않는다.
5. 다음 연결 검사를 실행한다.

```bash
export MONGODB_URI='<ATLAS_SRV_URI>'
export MONGODB_DATABASE='chat'
mongosh "$MONGODB_URI" --quiet --eval \
  "db.getSiblingDB('${MONGODB_DATABASE}').runCommand({ ping: 1 })"
```

`{ ok: 1 }`이 아니면 다음 단계로 진행하지 않는다. Atlas의 연결 수, CPU, storage, replication lag, opcounters와 애플리케이션의 MongoDB timeout/retry 지표를 모니터링한다.

### 애플리케이션 변경 계약

현재 저장소에는 MySQL 채팅 테이블의 실제 schema나 MongoDB repository/CDC 구현이 없으므로, 아래 계약을 구현하고 부하 테스트를 통과하기 전에는 백필을 시작하지 않는다.

#### 권장: Transactional Outbox

MySQL 메시지 트랜잭션과 같은 트랜잭션에서 `chat_migration_outbox` 이벤트를 기록한다. 별도 worker가 outbox를 읽어 MongoDB에 멱등적으로 적용하고, 성공한 이벤트를 완료 처리한다.

```sql
CREATE TABLE chat_migration_outbox (
  event_id       BINARY(16) PRIMARY KEY,
  message_id     VARCHAR(128) NOT NULL,
  event_type     VARCHAR(16) NOT NULL,
  aggregate_seq  BIGINT NOT NULL,
  payload_json   JSON NOT NULL,
  created_at     TIMESTAMP(6) NOT NULL,
  processed_at   TIMESTAMP(6) NULL,
  retry_count    INT NOT NULL DEFAULT 0,
  last_error     TEXT NULL,
  UNIQUE KEY uq_message_event (message_id, event_type, aggregate_seq)
);
```

worker는 `processed_at IS NULL` 이벤트를 `FOR UPDATE SKIP LOCKED` 또는 안전한 claim 방식으로 가져온다. MongoDB 쓰기는 `replaceOne({_id: message_id}, document, {upsert: true})`처럼 수행하고, 삭제는 soft delete 이벤트로 처리한다. MongoDB 반영 성공 후 outbox를 완료 처리한다. worker가 중단되어도 같은 이벤트를 다시 처리할 수 있어야 한다.

#### 반드시 필요한 API 동작

- 쓰기 응답은 MySQL 트랜잭션과 outbox 저장 성공 후 반환한다.
- MongoDB 반영 지연이 있어도 전환 전 읽기는 MySQL에서 최신 데이터를 제공한다.
- `GET` 응답의 `source`, `last_event_id`, `replication_lag`를 내부 지표로 남긴다.
- MongoDB 읽기에서 문서가 없으면 즉시 MySQL로 조용히 대체하지 않는다. 누락을 지표화하고 짧은 재시도 후 명시적인 복구 경로를 실행한다.
- 재시도는 exponential backoff와 최대 시도 횟수를 사용한다. poison event는 별도 dead-letter 상태로 남기며 삭제하지 않는다.
- 백필과 live outbox worker가 같은 문서를 동시에 갱신해도 최신 `aggregate_seq`가 낮은 이벤트가 높은 이벤트를 덮어쓰지 않도록 version guard를 둔다.

### 단계별 실행 순서

#### 1. 사전 검증 및 쓰기 경로 배포

- MySQL schema freeze를 선언한다. 채팅 컬럼 변경은 마이그레이션 완료까지 금지한다.
- MySQL 쓰기 트랜잭션에 outbox 이벤트 기록을 배포하고, worker를 MongoDB **write-only** 모드로 실행한다.
- 신규 메시지 생성, 수정, 삭제, 방 나가기/정리 이벤트가 모두 outbox에 기록되는지 확인한다.
- 같은 `message_id`를 두 번 처리해도 문서가 하나이고, sequence가 역행하지 않는지 테스트한다.
- worker 실패율, outbox backlog, oldest event age, MongoDB write error를 알람으로 설정한다.

#### 2. 과거 데이터 백필

백필은 PK 또는 `(conversation_id, sequence, message_id)` 커서 기반으로 작은 batch를 사용한다. offset pagination과 전체 테이블 단일 transaction은 사용하지 않는다.

각 batch에서 다음 순서를 지킨다.

1. MySQL에서 커서 이후 메시지를 읽는다.
2. `_id=message_id`로 MongoDB upsert한다.
3. `bulkWrite` 결과와 오류를 기록한다.
4. 실패 batch는 cursor를 진행시키지 않고 재시도한다.
5. 성공한 마지막 cursor와 처리 건수를 영속적으로 기록한다.

백필 중에도 live outbox worker를 계속 실행한다. 백필 문서와 live 이벤트가 경합할 수 있으므로 `aggregate_seq` 조건부 upsert를 사용한다. 예시 판정은 다음과 같다.

```javascript
db.messages.replaceOne(
  { _id: doc._id, $or: [
    { sequence: { $exists: false } },
    { sequence: { $lte: doc.sequence } }
  ]},
  doc,
  { upsert: true }
)
```

백필 완료 조건은 “읽은 행 수 = 성공 upsert 수 + 명시적으로 기록된 영구 실패 수”이며, 영구 실패 수는 0이어야 한다. outbox backlog가 0이고 oldest event age가 허용 임계값 이하일 때만 다음 단계로 진행한다.

#### 3. 정합성 검증

전체를 한 번에 비교하지 말고 다음 검증을 모두 수행한다.

- 전체 메시지 수, conversation별 메시지 수
- 최소/최대 `sequence`, 최소/최대 `created_at`
- 결정적 샘플의 `_id`, sender, body hash, sequence, 삭제 상태
- 삭제/수정 이벤트가 있는 메시지
- 최근 N분 동안 생성된 메시지
- 백필 cursor와 outbox의 마지막 event 순서

body 원문을 로그에 남기지 말고 `SHA-256(canonicalized_body)`만 비교 로그에 저장한다. 불일치 목록에는 `message_id`, MySQL 값, MongoDB 값의 hash, 마지막 event sequence, 재처리 횟수를 기록한다. 불일치가 하나라도 있으면 읽기 전환하지 않는다.

#### 4. Shadow read와 카나리 전환

먼저 실제 사용자 응답에는 MySQL 결과를 사용하면서 동일한 query를 MongoDB에도 보내 결과를 비교하는 shadow read를 1개 이상의 업무 피크 동안 실행한다. shadow read가 MongoDB 장애를 MySQL 응답에 전파하지 않도록 timeout과 격리를 둔다.

그 다음 내부 운영 계정 또는 전체 요청의 작은 비율만 MongoDB 읽기로 전환한다. 카나리 기간 동안 다음 조건을 모두 만족해야 한다.

- 누락 문서 0건
- sequence 역행 0건
- 정합성 불일치 0건
- MongoDB timeout/error rate가 사전 정의 임계값 미만
- 채팅 메시지 왕복 지연과 연결 오류가 MySQL 기준보다 악화되지 않음

#### 5. MongoDB 읽기 전환

feature flag를 사용해 읽기 대상을 `MYSQL`에서 `MONGODB`로 바꾼다. 쓰기는 계속 MySQL + outbox를 원본으로 유지한다. 전환 시점과 flag 변경자를 기록한다. 전환 직후 신규 메시지 생성·수정·삭제·페이지네이션·재접속 시나리오를 실제 API로 확인한다.

MongoDB가 일시적으로 장애가 나면 자동으로 무제한 MySQL fallback하지 않는다. 짧은 circuit breaker와 운영 flag로 읽기를 MySQL로 되돌리고, outbox backlog와 정합성을 확인한다.

#### 6. MongoDB 단독 쓰기/원본 폐기

MongoDB를 단독 쓰기 원본으로 바꾸는 것은 별도 변경이다. 다음 조건을 만족하기 전에는 MySQL 채팅 테이블과 outbox를 삭제하지 않는다.

- MongoDB 쓰기 경로가 MySQL 트랜잭션 없이도 완전한 validation, authorization, idempotency, ordering을 보장한다.
- 최소 한 번의 업무 피크와 백업 복구 리허설을 완료한다.
- MongoDB Atlas PITR 복구와 애플리케이션 재연결을 검증한다.
- MySQL으로의 rollback이 더 이상 필요 없다는 명시적 승인을 받는다.

승인 후에도 먼저 MySQL 채팅 쓰기를 막고, 최종 outbox backlog를 0으로 만든 뒤 스냅샷을 보존한다. 테이블 삭제는 별도 승인 이후에만 수행한다.

### 롤백 절차

읽기 전환 후 문제 발생 시 다음 순서로 복구한다.

1. MongoDB 읽기 feature flag를 `MYSQL`로 되돌린다.
2. MongoDB write-only worker와 outbox 처리는 즉시 중지하지 말고 backlog를 보존한다. MongoDB가 정상이라면 계속 반영해 복귀 후 재검증할 수 있게 한다.
3. MySQL에서 최근 메시지와 오류 샘플을 확인한다.
4. MongoDB 불일치 또는 backlog 원인을 수정한 뒤 shadow read를 재수행한다.
5. MongoDB 데이터가 손상된 경우에만 worker를 중지하고, MySQL을 원본으로 재백필한다.

MongoDB에만 존재하는 쓰기를 허용한 뒤에는 MySQL 단순 flag 원복으로 rollback할 수 없다. 이 상태에서는 barrier로 신규 쓰기를 잠시 대기시키고, 양쪽의 마지막 event sequence를 비교해 단일 원본을 결정한 뒤 충돌을 해결해야 한다.

### 운영 중단 기준

다음 중 하나라도 발생하면 MongoDB 읽기 전환을 중단하거나 즉시 MySQL 읽기로 되돌린다.

- outbox oldest event age가 SLA를 초과
- MongoDB write error, timeout 또는 connection pool 고갈
- 정합성 검증 불일치 1건 이상
- conversation 내 sequence 역행 또는 중복
- Atlas 백업/PITR 또는 네트워크 경로가 검증되지 않음
- 애플리케이션이 MongoDB 문서 누락을 재시도/복구하지 않고 성공 응답함