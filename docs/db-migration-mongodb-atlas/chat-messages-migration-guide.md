# RDS MySQL 채팅 데이터 -> MongoDB Atlas 무중단 분리

이 절차는 RDS MySQL의 채팅 데이터를 MongoDB Atlas로 옮기는 별도 마이그레이션이다.<br>
MySQL→RDS 전환과 동시에 수행하지 않는다.<br>
Atlas로 읽기를 전환한 뒤에도 MySQL 원본과 변경 이력을 rollback window 동안 보존한다.

- RDS MySQL 버전: 8.4
- MongoDB Atlas 버전: 9.0

---

## 1. 기술적 의사결정 및 비교 분석

<details>
<summary>1. 기본키(PK) 및 식별자 전략: ObjectId 도입과 과거 데이터 처리 방식</summary>

### 배경 및 고민
MySQL에서는 `@GeneratedValue(strategy = GenerationType.IDENTITY)`로 1씩 증가하는 `Long id`를 사용하고 있었다. MongoDB로 넘어가면서 `created_at` 필드가 있으므로 정수형 ID가 불필요한지, 그리고 MongoDB의 12바이트(24자리 Hex) BSON `ObjectId`를 기본키(`_id`)로 그대로 사용해도 되는지 검토가 필요했다. 또한 기존 MySQL에 저장된 정수형 ID를 억지로 24자리 Hex로 변환해야 하는지에 대한 선택지가 갈렸다.

### 선택지 비교

| 방식 | 설명 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. `_id: String` 선언 후 MySQL 정수형 ID 문자열 유지** | 기존 ID는 `"1052"`처럼 문자열로 넣고, 신규 데이터만 `ObjectId` Hex 문자열 할당 | 기존 식별자 체계와 클라이언트 호환성 100% 보존 | 문자열 사전식 정렬 문제로 `_id` 단독 정렬 불가, `{ createdAt: -1, _id: -1 }` 복합 정렬/인덱스 강제 |
| **B. MySQL ID를 24자리 0 패딩 Hex로 변환** | `00000000000000000000041c` 형태로 억지 BSON 변환 | 단일 `ObjectId` BSON 타입 유지 | 타임스탬프가 1970년으로 왜곡되어 정렬 파괴, 불필요한 변환 비용 |
| **C. `created_at` 타임스탬프 주입 기반 신규 `ObjectId` 부여 (채택)** | 기존 레코드의 `created_at`을 앞 4바이트에 주입한 실제 `ObjectId`를 발급하여 `_id`로 사용 | 전체 컬렉션이 완전한 `ObjectId` 단일 체계를 갖추며 `{ chatRoomId: 1, _id: -1 }`로 인덱스 및 쿼리 최적화 | 타 도메인 및 클라이언트의 식별자를 24자리 Hex로 전환하는 작업 필요 |

### 결론: 방식 C 채택 및 점진적 확장(Expand-Contract)
`created_at`만으로는 밀리초(ms) 단위 동시 쓰기 시 정렬 역전이 발생하므로 단조 증가 카운터가 포함된 고유 식별자가 필수적이다. 
MongoDB의 인덱스 캐시 효율과 단일 키 레인지 스캔 성능을 극대화하기 위해 **방식 C**를 선택한다. 기존 MySQL 테이블에 `message_object_id CHAR(24)`를 추가하여 과거 데이터와 신규 데이터 모두에 타임스탬프가 주입된 유효한 `ObjectId`를 사전에 확정하고, 클라이언트 DTO 식별자를 `String messageId`로 통일한다.

</details>

<details>
<summary>2. 다중 WAS 환경 트래픽 동적 라우팅 방식 (Zero-Downtime Cutover)</summary>

### 배경 및 고민
WAS가 다중 인스턴스(Multi-AZ ASG)로 동작하는 환경에서 재배포 없이 런타임에 Read/Write 트래픽을 MySQL에서 MongoDB로 전환하고, 장애 시 수초 내 롤백할 수 있는 라우팅 메커니즘이 필요했다. RDB용인 `AbstractRoutingDataSource`는 NoSQL인 MongoDB에 적용할 수 없으므로 애플리케이션 라우팅 계층의 전역 플래그 동기화 도구를 결정해야 했다.

### 선택지 비교

| 방식 | 지연 시간 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. MySQL 메타 테이블 Polling (3초 주기)** | 최대 수초 | 추가 인프라 구축 없음 | **Split-Brain 윈도우 발생**: WAS 간 전환 시차로 동일 방 메시지 순서 역전 위험. MySQL 장애 시 플래그 변경 불가(롤백 불가). |
| **B. Consul / Spring Cloud Bus** | 수백 ms | 표준 MSA 형상 관리 | 단기 마이그레이션 대비 과도한 오버엔지니어링 |
| **C. Redis Pub/Sub + Key 백업 (채택)** | **수 ms 이내** | 인프라 추가 없음(기존 Redis 재활용), 전 WAS 즉시 일괄 동기화 | Redis 일시 다운 시 Fallback 필요 (로컬 메모리 캐싱으로 보완) |

### 결론: 방식 C (Redis Pub/Sub) 채택
Write 컷오버 시 단 1~2초의 WAS 간 반영 시차(Split-Brain)도 메시지 순서 역전을 부를 수 있다. 이미 구축된 Redis 인프라를 활용하여 `PUBLISH migration-channel "WRITE:MONGO"` 명령을 통해 **모든 WAS가 10ms 이내에 동시에 메모리 라우터를 전환**하도록 구성한다. 신규 기동되는 인스턴스는 Redis Key(`config:migration:*`)에서 초기 상태를 동기화한다.
세
</details>

<details>
<summary>3. 실시간 변경분 복제 파이프라인 (Debezium Direct CDC vs WAS Outbox)</summary>

### 배경 및 고민
MySQL에서 발생하는 실시간 쓰기 변경분을 MongoDB Atlas로 전달하는 방식으로, 애플리케이션 레벨의 Transactional Outbox 패턴을 구현할 것인지, 아니면 인프라 레벨의 Debezium(CDC)을 사용할 것인지 검토했다.

### 선택지 비교

| 방식 | 아키텍처 복잡도 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. Spring Boot 내부 Outbox Worker (스케줄러)** | 애플리케이션 레벨 | 외부 인프라 추가 불필요 | 스케줄러 폴링 DB 부하, 복제 지연(Replication Lag)에 따른 읽기 컷오버 정합성 이슈 |
| **B. Debezium Outbox Event Router** | 커넥터 + Outbox | 도메인 이벤트 정밀 제어 | Outbox 테이블 관리와 Debezium 운영 비용이 모두 발생 |
| **C. Debezium Direct CDC (Binlog 기반) (채택)** | 인프라 레벨 | WAS 코드 수정 없음, Binlog 기반 실시간 스트리밍, `chat_outbox_events` 테이블 불필요 | Kafka Connect / Debezium Connector 설정 필요 |

### 결론: 방식 C (Debezium Direct CDC) 채택
기존에 Kafka 클러스터를 이미 운영 중이므로, WAS 내부에 스케줄러 쿼리(`SKIP LOCKED`)를 작성하고 별도 Outbox 테이블을 유지할 이유가 없다. 
MySQL의 `binlog`를 직접 구독하는 **Debezium MySQL Connector**를 띄우고, 전용 Kafka 토픽(`chat.message.cdc.v1`)과 MongoDB Sink Connector를 연결하여 **애플리케이션 비간섭형 무손실 실시간 복제 파이프라인**을 구성한다. 단순 컬럼 매핑(`message_object_id` -> `_id`)은 커넥터 SMT(Single Message Transform)로 해결한다.

</details>

<details>
<summary>4. 과거 데이터 백필(Backfill) 방식</summary>

### 배경 및 고민
Debezium 자체의 초기 스냅샷(`snapshot.mode: initial`)으로 과거 데이터까지 한 번에 긁어올 것인지, 아니면 별도의 백필 배치를 돌릴 것인지 검토했다. 또한 RDS MySQL이 Multi-AZ Standby(Warm Standby, 외부 쿼리 불가)로 구성되어 있어 Primary DB 부하 격리가 핵심 과제였다.

### 선택지 비교

| 방식 | 부하 통제력 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. Debezium Initial Snapshot (All-in-One)** | 낮음 (통제 불가) | 배치 프로그램 개발 공수 0 | Primary DB 풀 스캔으로 Buffer Pool 오염. 실패 시 처음부터 재시도 리스크. 스냅샷 도중 Binlog Purge 위험. |
| **B. Spring Boot CommandLineRunner 단발 스크립트** | 보통 | 빠른 개발 | 대량 데이터 처리 중단 시 상태 관리 번거로움, 운영 리소스 격리 부족 |
| **C. Spring Batch 전용 프로세스 + No-Offset 페이징 (채택)** | **매우 높음** | **Chunk 단위 트랜잭션, 실패 지점 자동 재개(Restartability), 쓰로틀링(Throttling) 자유 제어** | 메타데이터 테이블 구성 필요 |

### 결론: 방식 C (Spring Batch) 채택 및 임시 Read Replica 활용
MySQL Primary의 안정성을 보장하기 위해 Debezium은 실시간 스트리밍(`snapshot.mode: schema_only`)만 담당하게 하고, 과거 데이터는 **Spring Batch 전용 배치 애플리케이션**으로 분리 실행한다.
- **RDS 부하 격리**: 백필 기간 동안만 AWS RDS **임시 Read Replica(읽기 전용 복제본)**를 생성하여 배치가 Replica를 읽도록 격리하거나, 야간 시간대에 Chunk당 `Thread.sleep(50ms)`을 두어 Primary CPU/Buffer Pool을 방어한다.
- **정합성 보장**: Debezium 실시간 스트림과 백필 배치가 겹치는 구간은 MongoDB의 **`_id` 기준 Upsert(덮어쓰기)**를 통해 자연스럽게 멱등 처리된다.

</details>

<details>
<summary>5. WAS–MongoDB Atlas 통신 방식</summary>

### 현재 상황과 목표
- WAS EC2는 public subnet에 있고 공인 IP를 사용한다. ASG가 EC2를 교체하거나 증감할 수 있어 인스턴스별 공인 IP가 바뀔 수 있다.
- 목표는 BE에서만 Atlas에 연결하고, 인스턴스 교체 때 Atlas 접근 목록을 수동으로 갱신하지 않는 것이다.
- Atlas 접근은 WAS의 송신 경로로 제한하고, 운영에서 `0.0.0.0/0`을 허용하지 않는다.

### 선택지 비교

| 방식 | 연결 경로 | 장점 | 고려 사항 |
|---|---|---|---|
| 공인 엔드포인트 직접 연결 | WAS → IGW → Atlas 공인 IP | 현재 public subnet 구성을 유지할 수 있다. | ASG 인스턴스 공인 IP가 바뀌면 Atlas 접근 목록 갱신이 필요하다. |
| NAT Gateway | WAS → NAT Gateway(EIP) → IGW → Atlas 공인 IP | 고정 송신 IP 하나를 Atlas 접근 목록에 등록할 수 있다. | NAT Gateway와 데이터 처리 비용이 추가되고, private subnet 중심으로 네트워크를 구성해야 한다. |
| **VPC Peering (채택)** | WAS VPC → Peering → Atlas VPC | 사설 경로를 사용하고 VPC CIDR을 허용하므로 인스턴스 IP 변경에 영향받지 않는다. 연결 자체의 시간 요금은 없다. | CIDR 중복 불가, 라우트와 보안 그룹 설정이 필요하다. AZ 간 데이터 전송료가 발생할 수 있다. |
| AWS PrivateLink | WAS VPC의 엔드포인트 → Atlas | Atlas로 향하는 접근 범위를 좁힌 사설 연결을 제공한다. | AWS 엔드포인트와 Atlas PrivateLink의 고정·사용량 비용이 추가된다. |

### 결론: VPC Peering 사용
현재 public subnet과 ASG 구조를 유지하면서 인스턴스별 공인 IP 허용 문제를 피하기 위해 앱 VPC와 Atlas 사이에 Peering을 사용한다. PrivateLink의 더 좁은 접근 범위는 장점이지만, 현재 운영 인력과 비용을 고려하면 추가 비용에 비해 이점이 크지 않다고 판단했다.<br>
Peering 연결 자체는 무료지만 전체 데이터 전송이 무료인 것은 아니다. WAS와 Atlas 노드가 서로 다른 AZ에 있을 때 전송료가 생길 수 있다. 트래픽 양과 primary 위치에 따라 달라지므로 dev 리허설에서 Atlas 청구 내역과 AWS Cost Explorer를 확인한다.<br>
구현 시 앱 VPC와 Atlas CIDR 중복 여부를 확인하고, Atlas CIDR 라우트를 Peering으로 지정한다. Atlas 접근 목록에는 앱 VPC CIDR을 등록하고, BE 보안 그룹에만 Atlas 목적지의 MongoDB 포트 송신을 허용한다. 현재 보안 그룹은 외부 HTTPS 443만 허용하므로 MongoDB 포트 규칙은 별도로 추가해야 한다. `0.0.0.0/0` 허용은 사용하지 않는다.

</details>

---

## 2. 전체 시스템 아키텍처 개요


```

[클라이언트 요청 (RPS 40)]
          │
          ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Spring Boot WAS (Multi-AZ Multi-Instance)                              │
│                                                                        │
│ [Dynamic Routing Control] ◀── (Redis Pub/Sub: READ/WRITE Target Flag)  │
│                                                                        │
│ [Write Path: Before Cutover]                                           │
│  └─ Primary Write: MySQL JPA (message_object_id 자동 채번)               │
│                                                                        │
│ [Write Path: After Cutover]                                            │
│  └─ Primary Write: MongoDB Atlas 직접 저장 (_id = message_object_id)     │
│  └─ (임시 안전망) MongoDB Change Streams ──> MySQL 역방향 복제              │
│                                                                        │
│ [Read Path] (Cutover 구간)                                              │
│  └─ @CircuitBreaker (Timeout: 500ms, SlowCall: 300ms)                  │
│       ├─ [Primary] Read MongoDB Atlas                                  │
│       └─ [Fallback] Read RDS MySQL (Circuit OPEN or Timeout 시)        │
└──────────────────┬──────────────────────────────────┬──────────────────┘
                   │                                  │
                   ▼ (JPA)                            ▼ (MongoTemplate)
         [RDS MySQL Instance (8.4)]                   [MongoDB Atlas (9.0)]
         - chat_messages                               - chat_messages collection
           (message_id PK, message_object_id)             (_id: ObjectId / 24-char Hex)
           │                                           - idx: { chatRoomId: 1, _id: -1 }
           │ (Binlog 캡처)                             ▲
           ▼                                          │
 [Debezium MySQL Connector]                           │
           │                                          │
           ▼                                          │
  [Kafka: chat.message.cdc.v1] ──────────────> [Mongo Sink Connector] (Upsert)
           ▲
           │ (과거 데이터 백필)
            [Spring Batch Backfill Job]

```

---

## 3. 단계별 실행 계획

> **배포 주기 요약**: WAS 정규 배포는 **2단계(1차 탑재)**와 **8단계(최종 정리)** 총 2회만 수행하며, 트래픽 전환(5, 6단계)은 **Redis Pub/Sub 명령으로 무중단(Zero-Downtime) 즉시 전환**한다.

| 단계 | 작업 내용 | 데이터 흐름 | 락/지연 영향도 | 롤백 전략 |
|---|---|---|---|---|
| **1. 스키마 확장 (Expand)** | - Flyway로 `chat_messages`에 `message_object_id CHAR(24) NULL` 컬럼 추가.<br>- `ALGORITHM=INSTANT` 적용.<br>*(유니크 인덱스는 DDL 락 및 백필 성능 저하 방지를 위해 1단계에서 생성하지 않음)* | 기존 트래픽 유지 (MySQL R/W) | **락/지연 없음**: 메타데이터만 변경되어 수 ms 이내 완료 | 추가된 컬럼 무시 또는 DDL 롤백 |
| **2. Dual-Gen 배포 & CDC 가동 (1차 WAS 배포)** | - WAS 1차 배포: 신규 JPA 엔티티 `@PrePersist`로 `message_object_id` 자동 생성(`new ObjectId().toHexString()`).<br>- Redis Pub/Sub 기반 동적 라우터 탑재 (기본값: `READ=MYSQL`, `WRITE=MYSQL`).<br>- Debezium Connector 실행 (`snapshot.mode: schema_only`). | **쓰기:** MySQL (신규 메시지에 `message_object_id` 포함)<br>**복제:** MySQL Binlog → Debezium → Kafka → Mongo Sink (Upsert)<br>**읽기:** MySQL | 지연 영향 없음 (단일 로컬 트랜잭션 유지) | Debezium 커넥터 일시 중지 및 직전 WAS 버전 롤백 |
| **3. 과거 데이터 Backfill (무배포)** | - Spring Batch Job 실행 (No-Offset 청크 1,000~2,000건).<br>- `message_object_id IS NULL`인 과거 레코드 순회.<br>- 각 레코드의 `created_at` 기반 `ObjectId` 생성 후 MySQL UPDATE 및 MongoDB Bulk Upsert.<br>- 임시 RDS Read Replica 또는 Throttling(50ms Sleep) 적용. | 백그라운드 배치 프로세스 → MySQL UPDATE & Mongo Bulk Upsert | Read Replica 사용 시 Primary 간섭 0%, Primary 직접 조회 시 CPU/IO 제어로 운영 영향 최소화 | 배치 프로세스 즉시 중지 (기존 서비스 비간섭) |
| **4. 인덱스 생성 & 정합성 검증 (무배포)** | - 백필 완료 확인 후, 필요 시 MySQL에 보조 인덱스 생성(`ALGORITHM=INPLACE, LOCK=NONE`).<br>- Debezium Kafka Consumer Lag 0 수렴 확인.<br>- MySQL vs MongoDB 건수(Count) 및 체크섬(Checksum) 검증.<br>- 타 도메인(알림/신고/읽음) 및 클라이언트 인터페이스의 식별자를 `message_object_id`로 전환. | 검증 쿼리 실행 + 연관 서비스 식별자 교체 | 영향 없음 | 식별자 참조 대상 다시 `message_id`로 원복 |
| **5. Read 컷오버 (무배포)** | - Redis Pub/Sub 명령 전파: `READ:MONGO`<br>- Circuit Breaker(Resilience4j) 가동 상태로 MongoDB 우선 조회 진입. | **쓰기:** MySQL (Debezium CDC 복제 유지)<br>**읽기:** Mongo 우선 조회 (지연/장애 시 MySQL Fallback) | Circuit Breaker Timeout 300~500ms 방어 | Redis Pub/Sub 명령으로 즉시 원복: `READ:MYSQL` |
| **6. Write 컷오버: Primary 전환 (무배포)** | - Redis Pub/Sub 명령 전파: `WRITE:MONGO`<br>- 신규 쓰기를 MongoDB로 직접 적재.<br>- (안전망) MongoDB Change Streams 기반 MySQL 역방향 복제 일시 가동. | **쓰기:** MongoDB 직접 적재<br>**읽기:** MongoDB 서빙<br>**임시 복제:** Mongo → MySQL (역방향 동기화) | 지연 영향 없음 (수 ms 내 전 WAS 동시 전환) | Redis Pub/Sub 명령으로 즉시 원복: `WRITE:MYSQL` (역방향 복제로 데이터 무손실) |
| **7. 역방향 동기화 중단 & 수렴 안정화 (무배포)** | - MongoDB 단독 운영 안정성 확인 (1~2주).<br>- 역방향 복제 파이프라인 중단 및 Debezium Connector 종료. | **쓰기:** MongoDB<br>**읽기:** MongoDB | 영향 없음 | 애플리케이션 레벨 롤백 불가 (DB 스냅샷 백업으로 복구) |
| **8. 레거시 정리: Contract (2차 WAS 배포)** | - WAS 코드에서 라우터 분기문, MySQL 레거시 엔티티/레포지토리, Redis 리스너 제거 후 2차 배포.<br>- MySQL `chat_messages` 테이블 하드 링크(`ln`) 트릭 적용 후 백그라운드 DROP. | MongoDB 단독 서빙 (MySQL 의존성 완전 제거) | 백그라운드 비동기 삭제로 InnoDB Buffer Pool 및 File System Lock 방어 | 덤프 보관 후 정리 완료 |

---

## 4. 사전 작업 명세

- **채팅 데이터 경계 정의**
  - `chat_messages` 테이블의 스키마와 컬럼 정의를 확인하고, MongoDB에서 동일한 데이터 구조를 유지할 수 있는지 검토한다.
  - `chat_messages` 컬렉션에 `{ chatRoomId: 1, _id: -1 }` 복합 인덱스를 구성하여 `_id` 자체의 시계열 단조 증가 특성을 활용한 고속 페이징 환경을 설계한다.
  - 채팅방 정보나 사용자 정보 등 다른 도메인 데이터는 RDB에 유지하고 채팅 메시지만 분리 이관함을 명확히 한다.
- **클라이언트 및 DTO 식별자 체계 정립**
  - 클라이언트 응답 DTO 필드의 식별자 타입을 `String messageId`로 통일한다.
  - MySQL 테이블의 기존 `message_id` PK는 그대로 보존하고, 신규 컬럼 `message_object_id CHAR(24)`를 추가하여 이중 식별자 호환 구조를 구축한다.
- **MySQL과 MongoDB 간의 데이터 모델 분리**
  - JPA `@Entity`(`ChatMessage`)와 MongoDB `@Document`(`ChatMessageDocument`) 모델을 별도 클래스로 정의하여 영속성 컨텍스트 및 트랜잭션 매니저 충돌을 방지한다.
- **Debezium CDC 및 Kafka 파이프라인 구성**
  - 기존 Kafka 클러스터 내에 마이그레이션 전용 토픽(`chat.message.cdc.v1`, Partition Key: `chat_room_id`)을 생성한다.
  - Debezium MySQL Connector를 등록하여 `chat_messages` 테이블의 binlog를 스트리밍하고, MongoDB Sink Connector를 구성하여 `_id = message_object_id` 기준 Upsert로 적재하도록 SMT를 설정한다.
- **다중 WAS 동적 라우팅 환경 구성**
  - WAS 재배포 없이 트래픽 대상을 전환/롤백할 수 있도록 Redis Pub/Sub 기반의 `MigrationConfigManager` 및 라우팅 레이어를 구현한다.
- **Spring Batch 과거 데이터 백필 Job 구현**
  - `message_object_id IS NULL`인 데이터를 No-Offset 청크 단위로 조회한다.
  - `created_at` 타임스탬프를 주입한 `new ObjectId(Date)`를 생성하여 MySQL `message_object_id` 컬럼에 UPDATE하고, MongoDB `_id`로 Bulk Upsert하는 멱등성 잡을 작성한다.
  - Primary 부하 방지를 위해 임시 Read Replica 연결 또는 Chunk 간 Sleep(Throttling) 설정을 포함한다.
- **데이터 정합성 검증 쿼리 작성**
  - MySQL과 MongoDB 간의 건수(Count) 및 체크섬(Checksum)을 비교하는 검증 스크립트를 작성한다.
  - Debezium의 Kafka Consumer Lag 지표를 모니터링하여 복제 지연이 0에 수렴하는지 확인한다.
- **읽기/쓰기 전환 안전망 및 Circuit Breaker 검증**
  - Circuit Breaker(Resilience4j)를 구성하여 MongoDB 읽기 지연(SlowCall > 300ms) 또는 장애 발생 시 즉시 MySQL로 Fallback되도록 검증한다.
  - 쓰기 전환 시 긴급 롤백을 지원하기 위해 MongoDB Change Streams 기반의 MySQL 역방향 복제 파이프라인을 사전 검증한다.
