# 스테이징 채팅 시험

서버 간 전달과 서비스 주소의 지속 연결은 `run_chat_pubsub.sh`, 브라우저 재연결 확인은 `run_reconnect_peer.sh`를 사용한다. HTTP 시험과 RUN_ID·fixture를 분리한다.

## 준비

- v1·v2에 같은 RDS·Valkey와 서버 간 Pub/Sub를 지원하는 BE 이미지를 사용한다. 기본 BE 2.0.2 SimpleBroker만으로는 서버 간 전달을 검증할 수 없다.
- `v1-origin.staging.bakkucca.com`은 시험 v1 EC2, `origin.staging.bakkucca.com`은 시험 v2 ALB를 가리켜야 한다. 두 주소의 TLS 인증서와 접근 규칙을 확인한다.
- 새 ID 범위로 SQL과 fixture를 생성하고 staging DB에 적용한다. SQL 적용 조건은 [공통 준비 절차](README.md#1-준비)와 같다.

```bash
python3 loadtest/cutover/seed_chat_pubsub.py --base 8600000 \
  --sql /tmp/chat-8600000.sql --fixture /tmp/chat-8600000.json
```

## 지속 송수신 — 부하 EC2

SQL 적용 후 fixture와 시험 코드를 부하 EC2로 전달한다. v1/v2 직접 연결 한 쌍과 서비스 주소 연결 한 쌍을 동시에 유지한다.

```bash
export RUN_ID=$(openssl rand -hex 5)
FIXTURE_FILE=/tmp/chat-8600000.json DURATION=900 \
  bash loadtest/cutover/run_chat_pubsub.sh
```

구독 대기 기본값은 500ms다. `SUBSCRIBE_WAIT_MS`를 늘린 시험은 초기 구독 직후의 무손실을 입증하지 않는다. 전환·롤백은 시험 종료 전에 수행한다.

```bash
python3 loadtest/cutover/verify_chat_pubsub.py --run "$RUN_ID" --export-sql \
  > "results/$RUN_ID/export.sql"
# staging RDS에 읽기 전용 SQL 실행 → results/$RUN_ID/db.tsv
python3 loadtest/cutover/verify_chat_pubsub.py --run "$RUN_ID" \
  --ledger "results/$RUN_ID/$RUN_ID-ledger.jsonl" \
  --db "results/$RUN_ID/db.tsv" --summary "results/$RUN_ID/$RUN_ID-summary.json"
```

`pass_continuous`는 송수신·DB 대조 결과다. 실제 원본 유입과 전환·롤백 구간은 원본 로그 및 작업 시점과 별도로 대조한다.

## 브라우저 재연결

로컬에서 시험 EC2와 같은 fixture를 지정한다.

```bash
python3 loadtest/cutover/browser_session.py --host "$CUTOVER_HOST" \
  --fixture /tmp/chat-8600000.json
```

출력된 로컬 페이지에서 시험 로그인 명령을 복사해 staging 브라우저 콘솔에서 실행한다. 실제 OAuth 검증을 대신하지 않는다.

부하 EC2에서 상대 사용자 송신을 실행한다.

```bash
export RUN_ID=$(openssl rand -hex 5)
FIXTURE_FILE=/tmp/chat-8600000.json bash loadtest/cutover/run_reconnect_peer.sh
```

상대 사용자는 연결 후 3초에 기준 메시지, 30·35·40초에 누락 확인용 메시지, 80초에 복귀 메시지를 보낸다. 브라우저를 기준 메시지 수신 후 오프라인으로 전환하고, 40초 이후 온라인으로 복귀시켜 재연결·누락 이력 복구를 확인한다. 자동 복구와 새로고침 후 이력 표시는 구분해서 기록한다. peer의 자기 수신·REST 이력 성공만으로 FE 복구를 통과 처리하지 않는다.

시험 결과는 저장소 루트 `results/`에 저장하며 커밋에서 제외한다. [과거 시험 기록](records/pubsub-rehearsal.md)은 재실행 결과를 대신하지 않는다.
