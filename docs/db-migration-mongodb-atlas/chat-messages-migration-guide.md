# RDS MySQL 채팅 데이터 -> MongoDB Atlas 무중단 분리

이 절차는 RDS MySQL의 채팅 데이터를 MongoDB Atlas로 옮기는 별도 마이그레이션이다.<br>
MySQL→RDS 전환과 동시에 수행하지 않는다.<br>
Atlas로 읽기를 전환한 뒤에도 MySQL 원본과 변경 이력을 rollback window 동안 보존한다.

- 데이터 특성: 메시지 추가 전용(Append-Only, 수정/삭제 불가), 부가기능(읽음/알림/신고) 없음
- RDS MySQL 버전: 8.4
- MongoDB Atlas 버전: 9.0

---

## 1. 기술적 의사결정 및 비교 분석

<details>
<summary>1. 기본키(PK) 및 정렬 전략: ObjectId 도입과 과거 데이터 처리 방식</summary>

### 배경 및 고민
MySQL에서는 `IDENTITY` 전략의 정수형 PK(`Long id`)를 사용하고 있었다. MongoDB로 이관 시 `created_at` 필드만으로 정렬할 경우 동일 밀리초 동시 쓰기 시 순서 역전이 발생할 수 있으므로 고유 타이브레이커가 필요했다. 또한 MongoDB 기본키인 `ObjectId`를 도입할 때 기존 MySQL 정수형 ID와의 호환 방식을 결정해야 했다.

### 선택지 비교

| 방식 | 설명 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. `_id: String` 선언 후 MySQL 정수형 ID 문자열 유지** | 기존 ID는 `"1052"`로 넣고 신규는 `ObjectId` Hex 할당 | 기존 식별자 체계 100% 보존 | 문자열 사전식 정렬 문제로 `_id` 단독 정렬 불가, `{ createdAt: -1, _id: -1 }` 복합 인덱스 강제 |
| **B. MySQL ID를 24자리 0 패딩 Hex로 변환** | `00000000000000000000041c` 형태로 변환 | 단일 BSON 타입 유지 | 타임스탬프 왜곡(1970년)으로 정렬 파괴, 불필요한 변환 비용 |
| **C. `created_at` 타임스탬프 주입 기반 신규 `ObjectId` 부여 (채택)** | 기존 레코드의 `created_at`을 앞 4바이트에 주입한 `ObjectId` 발급 및 `_id` 사용 | 전체 컬렉션이 단일 `ObjectId` 체계를 갖추며 `{ chatRoomId: 1, _id: -1 }`로 인덱스 및 커서 쿼리 최적화 | 클라이언트 식별자를 24자리 Hex(`String messageId`)로 전환 필요 |

### 결론: 방식 C 채택 및 점진적 확장(Expand-Contract)
메시지는 수정/삭제가 없는 불변 데이터이므로, 기존 MySQL 테이블에 `message_object_id CHAR(24)`를 추가하여 과거 데이터 백필 및 신규 데이터 생성 시 `created_at` 기반의 유효한 `ObjectId`를 확정한다. 클라이언트 DTO 인터페이스는 `String messageId`로 통일한다.

</details>

<details>
<summary>2. 다중 WAS 환경 트래픽 동적 라우팅 방식 (Zero-Downtime Cutover)</summary>

### 배경 및 고민
WAS가 다중 인스턴스(Multi-AZ ASG)로 동작하는 환경에서 재배포 없이 런타임에 Read/Write 트래픽을 전환해야 한다. `AbstractRoutingDataSource`는 NoSQL인 MongoDB를 지원하지 않으므로 애플리케이션 라우팅 계층을 구현해야 한다. 단순 Redis Pub/Sub만 사용할 경우 네트워크 단절, 지연 등으로 인해 WAS 간 상태 불일치(Split-Brain) 및 메시지 분할 적재 위험이 존재한다.

### 선택지 비교

| 방식 | 동기화 보장 수준 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. 단순 Redis Pub/Sub 전파** | Best-effort (보장 불가) | 구현 단순 | WAS 일시 단절/지연 시 메시지 유실, 전환 완료 확인 불가로 Split-Brain 발생 |
| **B. MySQL 메타 테이블 Polling (3초 주기)** | 주기적 수렴 | 인프라 추가 없음 | WAS 간 최대 수초 시차 발생, 전환 과도기 순서 꼬임 |
| **C. Redis Key 버전 관리 + Pub/Sub 알림 + WAS ACK 수집 (채택)** | ** 보장 (Verifiable)** | 수 ms 내 전파, 전환 완료 검증 가능, 낙오 WAS 주기적 폴링 복구 | 상태 관리 및 ACK 확인 로직 구현 필요 |

### 결론: 방식 C (버전 기반 상태 머신 + ACK 검증) 채택
설정의 원본(Redis Key)과 전파 수단(Pub/Sub)을 분리한다. 상태 변경 시 버전을 증가시키고 Pub/Sub으로 브로드캐스팅한 뒤, 각 WAS가 적용 완료 ACK를 Redis에 기록하게 하여 **모든 활성 WAS의 전환이 확인된 후에만 다음 단계로 진행**한다.

</details>

<details>
<summary>3. 실시간 변경분 복제 파이프라인 (Debezium Direct CDC vs WAS Outbox)</summary>

### 배경 및 고민
MySQL의 실시간 쓰기 변경분을 MongoDB Atlas로 전달하는 방식으로, 애플리케이션 레벨의 Outbox 패턴과 인프라 레벨의 Debezium(CDC)을 검토했다. 메시지는 추가 전용(Append-Only)이며 부가기능이 없다.

### 선택지 비교

| 방식 | 아키텍처 복잡도 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. Spring Boot 내부 Outbox Worker** | 애플리케이션 레벨 | 외부 인프라 불필요 | 스케줄러 DB 폴링 부하, 복제 지연 발생, 별도 Outbox 테이블 관리 필요 |
| **B. Debezium Direct CDC (Binlog 기반) (채택)** | 인프라 레벨 | WAS 코드 수정 없음, Binlog 기반 실시간 스트리밍, `chat_outbox_events` 테이블 불필요 | Kafka Connect 설정 및 RDS Binlog 사전 설정 필요 |

### 결론: 방식 B (Debezium Direct CDC) 채택
이미 Kafka 클러스터를 운영 중이므로, 별도의 Outbox 테이블 생성 및 스케줄러 개발 없이 MySQL의 `binlog`를 직접 구독하는 **Debezium MySQL Connector**를 사용한다. 수정/삭제가 없으므로 Tombstone이나 복잡한 삭제 핸들링 없이 순수 INSERT 스트림만 MongoDB Sink Connector로 전달한다.

</details>

<details>
<summary>4. 과거 데이터 백필(Backfill) 방식</summary>

### 배경 및 고민
Debezium의 초기 스냅샷(`snapshot.mode: initial`)으로 과거 데이터까지 한 번에 복제할 것인지, 아니면 별도의 백필 배치를 돌릴 것인지 검토했다. RDS MySQL이 Multi-AZ Standby(Warm Standby, 외부 쿼리 불가)로 구성되어 있어 Primary DB 부하 격리가 필수적이다.

### 선택지 비교

| 방식 | 부하 통제력 | 장점 | 단점 및 리스크 |
|---|---|---|---|
| **A. Debezium Initial Snapshot** | 낮음 (통제 불가) | 배치 개발 공수 0 | Primary DB 풀 스캔으로 Buffer Pool 오염, 실패 시 처음부터 재시도 리스크, Binlog 보관 주기 만료 위험 |
| **B. Spring Batch 전용 프로세스 + No-Offset 페이징 (채택)** | **매우 높음** | **Chunk 단위 트랜잭션, 실패 지점 자동 재개(Restartability), 쓰로틀링 자유 제어** | 배치 개발 및 메타데이터 테이블 필요 |

### 결론: 방식 B (Spring Batch) 채택
Debezium은 실시간 스트리밍(`snapshot.mode: no_data`)만 담당하게 하고, 과거 데이터는 **Spring Batch 전용 잡**으로 분리 실행한다.
- **RDS 부하 격리**: 백필 기간 동안만 AWS RDS 임시 Read Replica(읽기 전용 복제본)를 생성하여 배치가 Replica를 읽도록 격리할 수도 있지만, 야간 시간대 rps가 40으로 예상되기에 사용하지 않는다. 대신 Chunk당 `Thread.sleep(50ms)` 쓰로틀링을 적용한다.
- **정합성 보장**: 메시지는 불변(Append-Only)이므로, Debezium 실시간 스트림과 백필 배치가 겹치는 구간은 MongoDB의 **`_id` 기준 Upsert(덮어쓰기)**를 통해 데이터 충돌이나 버전 역전 없이 자연스럽게 멱등 처리된다.

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
│ [Dynamic Routing Control]                                              │
│  └─ State Machine: Redis Key Version 관리 + Pub/Sub + ACK 수집 검증     │
│                                                                        │
│ [Write Path: Before Cutover]                                           │
│  └─ Primary Write: MySQL JPA (message_object_id 사전 생성 및 INSERT)   │
│                                                                        │
│ [Write Path: After Cutover]                                            │
│  └─ Primary Write: MongoDB Atlas 직접 저장 (_id = message_object_id)   │
│  └─ (임시 안전망) MongoDB Change Streams ──> MySQL 역방향 복제        │
│                                                                        │
│ [Read Path] (Cutover 구간)                                              │
│  └─ Driver Timeout (500ms) + @CircuitBreaker (SlowCall: 300ms)         │
│       ├─ [Primary] Read MongoDB Atlas                                  │
│       └─ [Fallback] Read RDS MySQL (Circuit OPEN or Timeout 시)        │
└──────────────────┬──────────────────────────────────┬──────────────────┘
                   │                                  │
                   ▼ (JPA)                            ▼ (MongoTemplate)
         [RDS MySQL Instance (8.4)]             [MongoDB Atlas (9.0)]
         - chat_messages                        - chat_messages collection
           (message_id PK, message_object_id)     (_id: ObjectId / 24-char Hex)
           │                                    - idx: { chatRoomId: 1, _id: -1 }
           │ (Binlog 캡처)                             ▲
           ▼                                          │
      [Debezium MySQL Connector]                      │
       │                                              │
       ▼                                              │
  [Kafka: chat.message.cdc.v1] ────────────────> [Mongo Sink Connector] (Upsert)
       ▲
       │ (과거 데이터 백필)
  [Spring Batch Backfill Job]

```

---

## 3. 단계별 실행 계획

| 단계 | 작업 내용 | 데이터 흐름 | 락/지연 영향도                            | 롤백 전략 |
|---|---|---|-------------------------------------|---|
| **1. 스키마 확장 (Expand)** | - Flyway로 `chat_messages`에 `message_object_id CHAR(24) NULL` 컬럼 추가.<br>- `ALGORITHM=INSTANT` 적용.<br>*(유니크 인덱스는 DDL 락 및 백필 성능 저하 방지를 위해 1단계에서 생성하지 않음)* | 기존 트래픽 유지 (MySQL R/W) | **락/지연 없음**: 메타데이터만 변경되어 수 ms 이내 완료 | 추가된 컬럼 무시 또는 DDL 롤백 |
| **2. Dual-Gen 배포 & CDC 가동 (1차 WAS 배포)** | - WAS 1차 배포: 신규 JPA 엔티티 `@PrePersist`로 `message_object_id` 자동 생성(`new ObjectId().toHexString()`).<br>- Redis 기반 상태 관리 및 라우팅 로직 탑재 (기본값: `MYSQL_PRIMARY`).<br>- Debezium Connector 실행 (`snapshot.mode: no_data`). | **쓰기:** MySQL (신규 메시지에 `message_object_id` 포함)<br>**복제:** MySQL Binlog → Debezium → Kafka → Mongo Sink (Upsert)<br>**읽기:** MySQL | 지연 영향 없음 (단일 로컬 트랜잭션 유지)            | Debezium 커넥터 일시 중지 및 직전 WAS 버전 롤백 |
| **3. 과거 데이터 Backfill (무배포)** | - Spring Batch Job 실행 (No-Offset 청크 1,000~2,000건).<br>- `message_object_id IS NULL`인 과거 레코드 순회.<br>- 각 레코드의 `created_at` 기반 `ObjectId` 생성 후 MySQL 조건부 UPDATE 및 MongoDB Bulk Upsert.<br>- Throttling(50ms Sleep) 적용. | 백그라운드 배치 프로세스 → MySQL UPDATE & Mongo Bulk Upsert | CPU/IO 제어로 운영 영향 최소화                | 배치 프로세스 즉시 중지 (기존 서비스 비간섭) |
| **4. 인덱스 생성 & 수렴 검증 (무배포)** | - 백필 완료 확인 후, 필요 시 MySQL에 보조 인덱스 생성(`ALGORITHM=INPLACE, LOCK=NONE`).<br>- Debezium Kafka Consumer Lag 0 수렴 및 Sink 적재 완료 확인.<br>- MySQL vs MongoDB 건수(Count) 및 샘플 데이터 정합성 검증. | 검증 쿼리 실행 | 영향 없음                               | 정합성 불일치 시 백필 배치 재실행 |
| **5. Read 컷오버 (무배포)** | - Redis 상태 전파: `READ_TARGET=MONGO`.<br>- 모든 WAS의 적용 ACK 확인.<br>- Driver Timeout(500ms) 및 Circuit Breaker 가동 상태로 MongoDB 우선 조회 진입. | **쓰기:** MySQL (Debezium CDC 복제 유지)<br>**읽기:** Mongo 우선 조회 (지연/장애 시 MySQL Fallback) | Timeout 및 Circuit Breaker로 장애 전파 차단 | Redis 상태 원복: `READ_TARGET=MYSQL` |
| **6. Write 컷오버: Primary 전환 (무배포)** | 1. **쓰기 차단 및 Drain**: 신규 쓰기 요청 일시 대기(1~2초), 잔여 MySQL 트랜잭션 완료.<br>2. **CDC 최종 수렴 확인**: 마지막 MySQL Binlog 이벤트의 MongoDB 적재 완료 확인.<br>3. **상태 전환**: Redis 상태 `WRITE_TARGET=MONGO` 전파 및 전 WAS ACK 확인.<br>4. **쓰기 재개**: MongoDB 직접 쓰기 시작.<br>5. **안전망 가동**: MongoDB Change Streams 기반 MySQL 역방향 복제 실행. | **쓰기:** MongoDB 직접 적재<br>**읽기:** MongoDB 서빙<br>**임시 복제:** Mongo → MySQL (역방향 동기화) | 전환 순간 짧은 쓰기 지연(수초 이내) 발생            | **2단계 롤백 절차 수행**: Mongo 쓰기 차단 → 역방향 동기화 수렴 확인 → MySQL 쓰기 재개 |
| **7. 역방향 동기화 중단 & 수렴 안정화 (무배포)** | - MongoDB 단독 운영 안정성 확인 (1~2주).<br>- Change Streams Resume Token 및 Lag 모니터링.<br>- 안정화 완료 승인 후 역방향 복제 파이프라인 및 Debezium Connector 영구 종료. | **쓰기:** MongoDB<br>**읽기:** MongoDB | 영향 없음                               | 애플리케이션 레벨 롤백 불가 (DB 스냅샷 백업으로 복구) |
| **8. 레거시 정리: Contract (2차 WAS 배포)** | - WAS 코드에서 라우터 분기문, MySQL 레거시 엔티티/레포지토리 정리 후 2차 배포.<br>- RDS MySQL 최종 스냅샷 생성 및 복원 검증.<br>- 트래픽 최저 시간대에 MySQL `chat_messages` 테이블 표준 `DROP TABLE` 실행. | MongoDB 단독 서빙 (MySQL 의존성 완전 제거) | DDL 실행 시 잠시 메타데이터 락 경합 가능 (트래픽 최저점 수행) | 스냅샷 보관 후 정리 완료 |

---

## 4. 사전 작업 명세

- **채팅 데이터 경계 정의**
  - `chat_messages` 테이블의 스키마와 컬럼 정의를 확인하고, MongoDB에서 동일한 데이터 구조를 유지할 수 있는지 검토한다.
  - `chat_messages` 컬렉션에 `{ chatRoomId: 1, _id: -1 }` 복합 인덱스를 구성하여 `_id` 자체의 시계열 단조 증가 특성을 활용한 고속 페이징 환경을 설계한다.
  - 채팅 메시지는 추가 전용(Append-Only)이며 수정/삭제 및 외부 연관 도메인(읽음/알림/신고)이 없음을 확인한다.
- **클라이언트 및 DTO 식별자 체계 정립**
  - 클라이언트 응답 DTO 필드의 식별자 타입을 `String messageId`로 통일한다.
  - MySQL 테이블의 기존 `message_id` PK는 그대로 보존하고, 신규 컬럼 `message_object_id CHAR(24)`를 추가하여 이중 식별자 호환 구조를 구축한다.
- **MySQL과 MongoDB 간의 데이터 모델 분리**
  - JPA `@Entity`(`ChatMessage`)와 MongoDB `@Document`(`ChatMessageDocument`) 모델을 별도 클래스로 정의하여 영속성 컨텍스트 및 트랜잭션 매니저 충돌을 방지한다.
- **RDS MySQL 파라미터 그룹 및 Binlog 사전 설정**
  - `binlog_format = ROW`, `binlog_row_image = FULL` 설정을 확인한다.
  - RDS 자동 백업이 활성화되어 있는지 확인하고, CDC 장애 복구 시간을 고려하여 `binlog retention hours`를 충분히 확보(최소 72~168시간)한다.
- **Debezium CDC 및 Kafka 파이프라인 구성**
  - 마이그레이션 전용 토픽(`chat.message.cdc.v1`, Partition Key: `chat_room_id`)을 생성한다.
  - Debezium MySQL Connector를 등록하되, 초기 스냅샷 없이 신규 변경분만 캡처하도록 `snapshot.mode: no_data`로 설정한다.
  - MongoDB Sink Connector를 구성하여 `_id = message_object_id` 기준 Upsert로 적재하도록 설정한다.
- **다중 WAS 동적 라우팅 및 상태 검증 환경 구성**
  - 단순 Pub/Sub의 신뢰성 한계를 보완하기 위해, Redis Key 버전 관리, Pub/Sub 변경 알림, 각 WAS의 적용 ACK 기록 및 주기적 폴링 복구 로직을 구현한다.
- **Spring Batch 과거 데이터 백필 Job 구현**
  - `message_object_id IS NULL`인 데이터를 No-Offset 청크 단위로 조회한다.
  - `created_at` 타임스탬프를 주입한 `new ObjectId(Date)`를 생성하여 MySQL `message_object_id` 컬럼에 UPDATE하고, MongoDB `_id`로 Bulk Upsert하는 멱등성 잡을 작성한다.
  - Primary 부하 방지를 위해 Chunk 간 Sleep(Throttling) 설정을 포함한다.
- **데이터 정합성 검증 쿼리 작성**
  - MySQL과 MongoDB 간의 건수(Count) 및 메시지 필드 일치 여부를 비교하는 검증 스크립트를 작성한다.
  - Kafka Consumer Lag 및 MongoDB Sink 적재 성공 여부, DLQ 건수를 확인한다.
- **읽기/쓰기 전환 안전망 및 Circuit Breaker 검증**
  - 드라이버 레벨 요청 Timeout(500ms)과 Circuit Breaker(Resilience4j)를 구성하여 MongoDB 읽기 실패 시 MySQL로 Fallback되도록 검증한다.
  - 쓰기 전환 시 긴급 롤백을 지원하기 위해 MongoDB Change Streams 기반의 MySQL 역방향 복제 파이프라인 및 2단계 롤백 절차(쓰기 차단 → 동기화 수렴 → MySQL 쓰기 재개)를 사전 검증한다.

