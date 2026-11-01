
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

## 단계별 실행 계획
단계| 작업 내용                                                                     |데이터 흐름|락/지연 영향도|
---|---------------------------------------------------------------------------|---|---|
1. 배포 및 Outbox 활성화| Flyway로 chat_outbox_events 테이블 생성 및 WAS 롤링 업데이트.                          |쓰기: MySQL (chat_messages + Outbox 저장)<br>복제: Outbox Worker → Mongo읽기: MySQL 서빙|지연 영향 없음 (단일 트랜잭션 내 로컬 INSERT)|
2. 과거 데이터 백필| "Outbox 테이블 생성 이전의 과거 데이터를 message_id 청크 단위(예: 1,000건)로 MongoDB에 Upsert." |백그라운드 배치 → Mongo Upsert|지연 영향 없음 (Read/Write 비간섭)|
3. 동기화 정합성 검증| "Outbox의 INIT 레코드 잔여량이 0에 수렴하는지 확인하고, MySQL과 Mongo의 건수/해시 검증."            |모니터링/대조 쿼리|지연 영향 없음
4. Read 컷오버| 설정 플래그 변경(readFromMongo: true).<br>Circuit Breaker 활성 상태로 읽기 진입.          |읽기: Mongo 우선 시도(지연/장애 시 즉시 MySQL Fallback)|최대 300~500ms 방어|
5. Write 컷오버| Primary 쓰기를 MongoDB로 전환.<br>(필요 시 Mongo to MySQL 역방향 복제 임시 유지).           |쓰기: MongoDB 직접 적재읽기: MongoDB 서빙|지연 영향 없음|
6. 레거시 정리 (Flyway)| 마이그레이션 안정화 후 Flyway로 chat_messages 및 chat_outbox_events 테이블 제거.           | Flyway DROP TABLE 실행|애플리케이션 영향 없음|