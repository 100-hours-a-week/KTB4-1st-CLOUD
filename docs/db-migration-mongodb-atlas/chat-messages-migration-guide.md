
## 전체 시스템 아키텍처 개요
```
[클라이언트 요청 (RPS 40)]
         │
         ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Spring Boot WAS (Multi-AZ Multi-Instance)                              │
│                                                                        │
│ [Write Path]                                                           │
│  └─ @Transactional                                                     │
│       ├─ 1. INSERT INTO chat_messages                                  │
│       └─ 2. INSERT INTO outbox_events (Status: INIT)                   │
│                                                                        │
│ [Async Outbox Worker] (Multi-instance safe: SKIP LOCKED)               │
│  └─ Poll INIT events ──(Upsert)──> [MongoDB Atlas]                     │
│                                                                        │
│ [Read Path] (Cutover 구간)                                              │
│  └─ @CircuitBreaker (Timeout: 500ms, SlowCall: 300ms)                  │
│       ├─ [Primary] Read MongoDB Atlas                                  │
│       └─ [Fallback] Read RDS MySQL (Circuit OPEN or Timeout 시)        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
               ┌────────────────────┴────────────────────┐
               ▼                                         ▼
      [RDS MySQL Instance]                      [MongoDB Atlas]
      - chat_messages                           - chat_messages collection
      - outbox_events (Flyway 관리)               - idx: chatRoomId + createdAt
```

<details>
<summary>WAS–MongoDB Atlas 통신 방식</summary>

### 현재 상황과 목표

- WAS EC2는 public subnet에 있고 공인 IP를 사용한다. ASG가 EC2를 교체하거나 증감할 수 있어 인스턴스별 공인 IP가 바뀔 수 있다.
- 목표는 BE에서만 Atlas에 연결하고, 인스턴스 교체 때 Atlas 접근 목록을 수동으로 갱신하지 않는 것이다.
- Atlas 접근은 WAS의 송신 경로로 제한하고, 운영에서 `0.0.0.0/0`을 허용하지 않는다.

### 선택지 비교

| 방식 | 연결 경로 | 장점 | 고려 사항 |
|---|---|---|---|
| 공인 엔드포인트 직접 연결 | WAS → IGW → Atlas 공인 IP | 현재 public subnet 구성을 유지할 수 있다. | ASG 인스턴스 공인 IP가 바뀌면 Atlas 접근 목록 갱신이 필요하다. |
| NAT Gateway | WAS → NAT Gateway(EIP) → IGW → Atlas 공인 IP | 고정 송신 IP 하나를 Atlas 접근 목록에 등록할 수 있다. | NAT Gateway와 데이터 처리 비용이 추가되고, private subnet 중심으로 네트워크를 구성해야 한다. |
| VPC Peering | WAS VPC → Peering → Atlas VPC | 사설 경로를 사용하고 VPC CIDR을 허용하므로 인스턴스 IP 변경에 영향받지 않는다. 연결 자체의 시간 요금은 없다. | CIDR 중복 불가, 라우트와 보안 그룹 설정이 필요하다. AZ 간 데이터 전송료가 발생할 수 있다. |
| AWS PrivateLink | WAS VPC의 엔드포인트 → Atlas | Atlas로 향하는 접근 범위를 좁힌 사설 연결을 제공한다. | AWS 엔드포인트와 Atlas PrivateLink의 고정·사용량 비용이 추가된다. |

### 결론: VPC Peering 사용

현재 public subnet과 ASG 구조를 유지하면서 인스턴스별 공인 IP 허용 문제를 피하기 위해 앱 VPC와 Atlas 사이에 Peering을 사용한다. PrivateLink의 더 좁은 접근 범위는 장점이지만, 현재 운영 인력과 비용을 고려하면 추가 비용에 비해 이점이 크지 않다고 판단했다.

Peering 연결 자체는 무료지만 전체 데이터 전송이 무료인 것은 아니다. WAS와 Atlas 노드가 서로 다른 AZ에 있을 때 전송료가 생길 수 있다. 트래픽 양과 primary 위치에 따라 달라지므로 dev 리허설에서 Atlas 청구 내역과 AWS Cost Explorer를 확인한다.

구현 시 앱 VPC와 Atlas CIDR 중복 여부를 확인하고, Atlas CIDR 라우트를 Peering으로 지정한다. Atlas 접근 목록에는 앱 VPC CIDR을 등록하고, BE 보안 그룹에만 Atlas 목적지의 MongoDB 포트 송신을 허용한다. 현재 보안 그룹은 외부 HTTPS 443만 허용하므로 MongoDB 포트 규칙은 별도로 추가해야 한다. `0.0.0.0/0` 허용은 사용하지 않는다.

</details>

## 단계별 실행 계획
단계| 작업 내용                                                                     |데이터 흐름|락/지연 영향도|
---|---------------------------------------------------------------------------|---|---|
1. 배포 및 Outbox 활성화| Flyway로 chat_outbox_events 테이블 생성 및 WAS 롤링 업데이트.                          |쓰기: MySQL (chat_messages + Outbox 저장)<br>복제: Outbox Worker → Mongo읽기: MySQL 서빙|지연 영향 없음 (단일 트랜잭션 내 로컬 INSERT)|
2. 과거 데이터 백필| "Outbox 테이블 생성 이전의 과거 데이터를 message_id 청크 단위(예: 1,000건)로 MongoDB에 Upsert." |백그라운드 배치 → Mongo Upsert|지연 영향 없음 (Read/Write 비간섭)|
3. 동기화 정합성 검증| "Outbox의 INIT 레코드 잔여량이 0에 수렴하는지 확인하고, MySQL과 Mongo의 건수/해시 검증."            |모니터링/대조 쿼리|지연 영향 없음
4. Read 컷오버| 설정 플래그 변경(readFromMongo: true).<br>Circuit Breaker 활성 상태로 읽기 진입.          |읽기: Mongo 우선 시도(지연/장애 시 즉시 MySQL Fallback)|최대 300~500ms 방어|
5. Write 컷오버| Primary 쓰기를 MongoDB로 전환.<br>(필요 시 Mongo to MySQL 역방향 복제 임시 유지).           |쓰기: MongoDB 직접 적재읽기: MongoDB 서빙|지연 영향 없음|
6. 레거시 정리 (Flyway)| 마이그레이션 안정화 후 Flyway로 chat_messages 및 chat_outbox_events 테이블 제거.           | Flyway DROP TABLE 실행|애플리케이션 영향 없음|
