# 인프라 전환 리허설

- 목적: v1 EC2 → v2 ECS 전환·롤백 중 요청 처리·데이터 저장·채팅 복구 확인
- 준비 조건: 시험용 v2 ECS·ALB·Valkey·Kafka와 v1 EC2
- staging DB 전용 Terraform만 적용해서는 실행할 수 없음
- DB 복제·이관 스크립트와 DB 마이그레이션 복제본은 변경하지 않음

| 구분 | 내용 |
|---|---|
| 서비스 주소 | `https://staging.bakkucca.com` 유지 |
| 변경 대상 | CloudFront 원본: v1 Nginx ↔ v2 ALB / FE 정적 S3 |
| 공통 자원 | 같은 staging RDS, 같은 Valkey, 호환되는 BE 설정 |
| HTTP 검증 | 조회, 물품 수정 / 삭제, 그룹 생성, 교환 요청 / 취소, DB 대조 |
| 채팅 검증 | 별도 스크립트로 송수신 / 저장 대조, 브라우저로 재연결 / 이력 복구 확인 |
| 제외 | DB 이관 자체 — `loadtest/migration` 사용 |

- 순서: 준비 → 트래픽 실행 → v2 전환 → 선택적 v1 롤백 → 결과 대조

## 1. 준비

- 환경: 별도 v1 복제본과 v2 ECS 기동, staging RDS / Valkey / Kafka 접근 확인
- 호환성: RDS 스키마, JWT, CORS, 쿠키, Kafka, Valkey 설정 확인
- 원본: 최초 `v1-app`, 전환 대상 `alb` / `fe-static`, TLS와 접근 SG 준비
- 도구: EC2에 Docker / Python 3, 로컬에 AWS CLI / jq / SSH
- 시험 중 다른 배포, Terraform apply, CloudFront 동시 변경 금지
- **사용한 fixture 재사용 금지 — RUN_ID만 바꿔도 삭제 물품과 교환 상태는 복구되지 않음**

- 실행 위치: 로컬 CLOUD 저장소 루트
- 시험 데이터: DB 담당자와 격리 범위를 확인한 미사용 ID로 생성

```bash
BASE_ID=8500000 # DB에서 미사용 범위 확인 후 지정
python3 loadtest/cutover/seed.py --base "$BASE_ID" \
  --sql "/tmp/cutover-$BASE_ID.sql" --fixture "/tmp/cutover-$BASE_ID.json"
```

- 생성 결과: SQL + fixture JSON — DB 자동 반영 없음
- SQL 검토: staging endpoint / `market`, ID 충돌, 소유권, 그룹 가입, 물품 수량 / 상태, 활성 교환 부재
- SQL 적용: 실제 접속 host를 `@cutover_endpoint`에 설정, `--force` 없이 적용
- 적용한 fixture JSON을 부하 EC2로 전달

## 2. 트래픽 실행 — 부하 EC2

```bash
sudo -i
cd /opt/app/shared/chat-pubsub-test
export RUN_ID=$(openssl rand -hex 5)
printf 'RUN_ID=%s\n' "$RUN_ID"
FIXTURE_FILE=/tmp/cutover-8500000.json \
FIXTURE_REVIEWED_RUN="$RUN_ID" CHAT_ENABLED=false MINUTES=15 RATE=1 \
  bash loadtest/cutover/run.sh
```

| 설정 | 동작 |
|---|---|
| `FIXTURE_FILE` | 1단계에서 적용한 새 fixture 경로 |
| `RATE=1` | 초당 조회 1회 |
| API 세션 | fixture 개수만큼 실행 |
| 물품 수정 | 6초마다 1회 |
| `CHAT_ENABLED=false` | HTTP만 실행 — 채팅 성공을 의미하지 않음 |
| 결과 | EC2의 `results/$RUN_ID/` |

- JWT: 실행 중인 시험 BE에서 읽음 — 키를 명령행에 직접 입력하지 않음
- HTTP 자동 재시도 없음, fixture 개수와 조회 / 수정 계획 상한 초과 실행 차단
- 채팅 병행: 별도 fixture로 `run_chat_pubsub.sh` 실행 — [채팅 시험 절차](CHAT.md) · [기존 시험 기록](records/pubsub-rehearsal.md)
- 긴 요청 확인 시에만 `LONG_REQUEST_PATH`, `LONG_REQUEST_MIN_MS` 지정. 지정하면 전환·롤백 시 진행 중인 긴 요청을 필수로 검증
- 진행 중 교환 요청은 참고 지표. 미관측 항목은 `unverified`에 표시하며 기본 통과 여부와 구분
- **전환 전후 관찰과 롤백까지 트래픽 유지 — 부하 종료 후 롤백은 부하 중 롤백으로 인정하지 않음**

## 3. v2 전환 — 로컬 제어 터미널

- EC2와 같은 `RUN_ID` 지정, `CUTOVER_HOST`는 새 복제본 공인 IP
- CloudFront 설정 백업 후 기본 원본을 `alb`, FE 정적 경로를 `fe-static`으로 변경
- `/images/*` 등 다른 원본 유지, DNS와 DB 변경 없음
- 전파 완료 후 페이지 / JS / 신규 WebSocket과 v2 요청 유입 확인

<details>
<summary>CloudFront 전환 명령</summary>

```bash
export RUN_ID=EC2에서_출력한_RUN_ID
export CUTOVER_HOST=새_복제본_공인_IP
TARGET="ec2-user@${CUTOVER_HOST:?새 복제본 공인 IP 지정}"
KEY="$HOME/.ssh/bakkucca_v1"
CF_ID=EC89XPEZQJIG0
mkdir -p "results/$RUN_ID"
aws cloudfront get-distribution-config --id "$CF_ID" > "results/$RUN_ID/cf-before.json"
jq -e '.DistributionConfig.Aliases.Items | index("staging.bakkucca.com") != null' "results/$RUN_ID/cf-before.json"
jq '.DistributionConfig
  | .DefaultCacheBehavior.TargetOriginId = "alb"
  | .CacheBehaviors.Items |= map(
      if .TargetOriginId == "v1-app" then
        .TargetOriginId = (if (.PathPattern | test("^/(api|ws)")) then "alb" else "fe-static" end)
      else . end)' "results/$RUN_ID/cf-before.json" > "results/$RUN_ID/cf-v2.json"
ssh -i "$KEY" "$TARGET" "sudo python3 /opt/app/shared/chat-pubsub-test/loadtest/cutover/mark.py --run $RUN_ID switch_start"
aws cloudfront update-distribution --id "$CF_ID" \
  --if-match "$(jq -r .ETag "results/$RUN_ID/cf-before.json")" \
  --distribution-config "file://$PWD/results/$RUN_ID/cf-v2.json" >/dev/null
aws cloudfront wait distribution-deployed --id "$CF_ID"
ssh -i "$KEY" "$TARGET" "sudo python3 /opt/app/shared/chat-pubsub-test/loadtest/cutover/mark.py --run $RUN_ID switch_complete"
```

`mark.py`는 작업 시점 기록용 — 엣지별 실제 전환 시점은 원본 로그로 대조

</details>

## 4. 선택적 v1 롤백 — 같은 제어 터미널

- **트래픽 실행 중** 백업한 v1 원본으로 복귀
- 현재 설정과 백업의 차이가 이번 원본 변경뿐인지 확인 — 다른 변경이 있으면 덮어쓰기 중단
- 전파 완료 후 요청 처리와 v2에서 작성한 데이터 조회 확인
- 롤백 생략 시 해당 항목은 미검증

<details>
<summary>CloudFront 롤백 명령</summary>

```bash
aws cloudfront get-distribution-config --id "$CF_ID" > "results/$RUN_ID/cf-current.json"
diff -u <(jq .DistributionConfig "results/$RUN_ID/cf-before.json") \
  <(jq .DistributionConfig "results/$RUN_ID/cf-current.json")
jq .DistributionConfig "results/$RUN_ID/cf-before.json" > "results/$RUN_ID/cf-v1.json"
ssh -i "$KEY" "$TARGET" "sudo python3 /opt/app/shared/chat-pubsub-test/loadtest/cutover/mark.py --run $RUN_ID rollback_start"
aws cloudfront update-distribution --id "$CF_ID" \
  --if-match "$(jq -r .ETag "results/$RUN_ID/cf-current.json")" \
  --distribution-config "file://$PWD/results/$RUN_ID/cf-v1.json" >/dev/null
aws cloudfront wait distribution-deployed --id "$CF_ID"
ssh -i "$KEY" "$TARGET" "sudo python3 /opt/app/shared/chat-pubsub-test/loadtest/cutover/mark.py --run $RUN_ID rollback_complete"
```

</details>

## 5. 결과 확인 — 부하 EC2

- 요청과 비동기 작업 종료 후 같은 RDS의 최종 상태 추출
- 응답 ID로 추출 범위 제한 — 과거 시험 데이터 혼입 방지

```bash
python3 loadtest/cutover/prepare_export.py --run "$RUN_ID" \
  --ledger "results/$RUN_ID/$RUN_ID-ledger.jsonl" > "results/$RUN_ID/export.sql"
# 기존 TLS MySQL 접속으로 export.sql 실행 → results/$RUN_ID/rds.tsv
python3 loadtest/cutover/verify.py --run "$RUN_ID" \
  --ledger "results/$RUN_ID/$RUN_ID-ledger.jsonl" \
  --summary "results/$RUN_ID/$RUN_ID-summary.json" \
  --phases "results/$RUN_ID/$RUN_ID-phases.jsonl" --rds "results/$RUN_ID/rds.tsv"
```

| 출력 | 확인할 내용 |
|---|---|
| `request_counts` / `plan_differences` | 계획 대비 실제 시작 / 완료 횟수 — 차이가 있으면 실패 |
| `read_totals` / `update_totals` | 실제 시작, 완료, 정상, 실패, 응답 누락 |
| `response_errors` / `db_errors` | HTTP 응답 오류 / 누락, DB 유실 / 중복 / 상태 불일치 |
| `unverified` / `cutover_coverage` | 진행 중 요청, 전환 구간, 롤백 등의 증거 부족 |
| `coverage_errors` / `errors` | 구간 검증 오류와 전체 실패 사유 |
| `passed=true` | 기본 HTTP·DB·전환/롤백 검증 통과. 활성화한 채팅·긴 요청 검증 포함 |

**HTTP 실패율 0%만으로 전체 무중단 통과 판정 금지**

- 자동 검증 밖: FE 화면, 실제 OAuth, AI 기능, Kafka 소비, BE 종료 후 채팅 복구
- 진행 중 요청 보장: 요청 시작 / 완료와 전환 시점이 겹친 실제 증거 필요
- 기존 WebSocket: 원본 변경만으로 v2에 이동하지 않음 — 재연결과 이력 복구 별도 확인
