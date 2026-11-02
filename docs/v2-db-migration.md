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

RDS MySQL 이관을 먼저 성공적으로 완료한 뒤, 채팅 데이터 MongoDB 분리를 별도로 진행한다.
- 인프라 물리 이관(동종 DB 동일 버전)과 이종 DB 및 비즈니스 로직 수정을 동시 진행하면 실패 원인 격리가 불가하다.
- 팀원 간 v1 -> v2 서비스 확장 계획을 합의한 결과, `[RDS 이관 -> 기타 구성 요소(WAS, ALB 등) 전환 -> 채팅 데이터 MongoDB 이관]` 순으로 단계별로 진행한다.

[[RDS MySQL 마이그레이션] 실행 가이드 문서 링크](db-migration-rds-mysql/rds-migration-guide.md)<br>
[[RDS MySQL 마이그레이션] 결과 보고서 문서 링크](db-migration-rds-mysql/rds-migration-report.md)<br>

[[MongoDB Atlas 마이그레이션] 실행 가이드 문서 링크](db-migration-mongodb-atlas/chat-messages-migration-guide.md)<br>
[[MongoDB Atlas 마이그레이션] 결과 보고서 문서 링크](db-migration-mongodb-atlas/chat-messages-migration-report.md)

## EC2 MySQL -> RDS MySQL 마이그레이션

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

