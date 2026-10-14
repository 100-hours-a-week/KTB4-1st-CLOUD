# 단일 계정 API 반복과 Nginx 사용자별 제한

복제 target에서 같은 계정으로 API를 반복 호출해 제한 전후를 비교한다. 공통 runner·target 준비는 [v1 부하테스트 안내](../README.md)를 따른다.

## 테스트 입력

| 항목 | 값 |
| --- | --- |
| target | t4g.small, 메모리 2GiB |
| runner | t4g.large |
| API | `POST /api/groups` |
| 사용자 | JWT `sub=1` 하나 |
| 요청 본문 | 기존 그룹 이름 `loadtest-group-1`을 반복 사용 |
| 부하 | 1 VU에서 시작해 30초 동안 800 VU까지 증가, 4분 30초 유지 |
| 반복 방식 | 각 VU가 응답을 받은 뒤 바로 다음 요청 전송, 대기 없음 |
| Nginx 메모리 한도 | 64MiB |

800 VU는 사용자 800명이 아니라 같은 계정의 동시 반복 요청 수다. P0와 P1은 같은 요청, target, runner, 메모리 한도로 실행한다.

## 파일 복사

로컬 CLOUD 레포 루트에서 target과 runner IP를 설정하고 attack 파일을 복사한다. SSH 키와 공통 환경 변수 설정 방법은 v1 부하테스트 안내를 참고한다.

```bash
TARGET_PUBLIC_IP='<target-public-ip>'
RUNNER_PUBLIC_IP='<runner-public-ip>'
LOADTEST_SSH_KEY="$HOME/.ssh/bakkucca_v1"

scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/attack "ec2-user@$TARGET_PUBLIC_IP:~/"
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/attack "ec2-user@$RUNNER_PUBLIC_IP:~/"
scp -r -i "$LOADTEST_SSH_KEY" nginx "ec2-user@$TARGET_PUBLIC_IP:~/attack/"
scp -i "$LOADTEST_SSH_KEY" nginx/default.conf "ec2-user@$TARGET_PUBLIC_IP:~/target/nginx/"
```

Nginx와 Spring Boot는 target의 `.env`에서 같은 `JWT_SECRET`을 환경변수로 받는다. runner의 `~/runner/.env`에도 target과 같은 테스트 `JWT_SECRET`과 target 사설 IP가 설정되어 있어야 한다.

## P0와 P1 실행

각 실행은 복제 target의 서비스가 healthy인 상태에서 시작한다. 실측 조건을 맞출 때는 P0와 P1 사이에 target을 재부팅하고 서비스 상태를 다시 확인한다. 데이터 시드와 서비스 이미지는 바꾸지 않는다.

target에서 아래 명령으로 기본 구성을 준비한다. P0는 사용자별 제한을 적용하지 않는다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --wait
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml \
  up -d --no-deps --force-recreate nginx
docker exec nginx nginx -t
curl -ksS https://127.0.0.1/health
```

P1에서는 target에서 Nginx만 rate limit 설정과 함께 다시 만든다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml \
  -f ../attack/docker-compose.rate-limit.yml up -d --no-deps --force-recreate nginx
docker exec nginx nginx -t
curl -ksS https://127.0.0.1/health
```

P1은 Nginx njs에서 HS256 JWT를 검증하고 전체 `/api/` 요청을 사용자 ID별로 합산해 초당 3건, burst 10, nodelay로 제한한다. API 경로와 HTTP 메서드를 바꿔도 같은 한도를 사용하며 초과 요청은 429로 응답한다. IP별 제한은 사용하지 않는다. 사용자 ID가 없는 로그인과 토큰 재발급 요청에는 사용자별 제한을 적용하지 않는다.

runner의 `~/runner`에서 P0 또는 P1을 실행한다. 각 실행마다 `PHASE`와 `TESTID`를 바꾼다.

```bash
PHASE=p0
cd ~/runner
TESTID="${PHASE}-$(date -u +%Y%m%dT%H%M%SZ)-800vu"
mkdir -p results
printf 'TESTID=%s\n' "$TESTID"
date -u +%FT%TZ > "results/$TESTID.start"
set -o pipefail
K6_SCRIPTS_DIR=../attack/k6 docker compose run --rm --no-deps --interactive=false --name "$TESTID" k6 run \
  --vus 1 --stage 30s:800 --stage 4m30s:800 \
  -e TESTID="$TESTID" \
  --out experimental-prometheus-rw \
  --out "json=/results/$TESTID.metrics.json.gz" \
  group-repeat.js 2>&1 | tee "results/$TESTID.log"
K6_EXIT=${PIPESTATUS[0]}
date -u +%FT%TZ > "results/$TESTID.end"
printf '%s\n' "$K6_EXIT" > "results/$TESTID.exitcode"
```

P0 실행과 함께 target의 별도 터미널에서 커널 로그를 확인한다. Nginx worker OOM 종료가 나오면 runner의 실행 터미널에서 `Ctrl+C`로 중단한다. P1은 5분 동안 실행하고 정상 종료 여부를 기록한다.

```bash
sudo journalctl -kf | grep --line-buffered -E 'Memory cgroup out of memory|Killed process .*\(nginx\)'
```

k6 결과는 runner의 `~/runner/results/`에 저장된다. 요약과 raw 지표를 로컬에 복사하고 Prometheus·Loki·Grafana에서 같은 TESTID와 실행 시간 구간을 조회한다.

```bash
mkdir -p "loadtest/v1/runner/results/$TESTID"
scp -i "$LOADTEST_SSH_KEY" \
  "ec2-user@$RUNNER_PUBLIC_IP:~/runner/results/$TESTID.*" \
  "loadtest/v1/runner/results/$TESTID/"
```

## 기록된 비교 결과

제한 전은 기존 OOM 재현 원본이고 제한 후는 전체 API에 사용자별 초당 3건, burst 10, nodelay를 적용한 실측이다.

| 결과 | P0: 제한 없음 | P1: 사용자별 제한 |
| --- | ---: | ---: |
| 실행 | 최초 worker OOM 뒤 중단, 약 97초 | 5분 정상 종료 |
| OOM 전 완료 요청 | 10,640건, 모두 409 | — |
| backend 전달 | — | 911건 |
| Nginx 429 응답 | 0건 | 1,175,941건 |
| worker OOM | 1회 | 0회 |

P1에서 많은 요청이 429로 빠르게 응답되므로 P0와 동일한 RPS 비교는 아니다. 최초 90초의 백엔드 전달은 9,914건에서 275건으로 97.23% 감소했다. 같은 계정과 API, 최대 800개 병렬 반복의 P1은 5분 동안 OOM과 예상 밖 오류가 0이었다. 정상 혼합 트래픽 성능은 별도 검증 대상이다.
