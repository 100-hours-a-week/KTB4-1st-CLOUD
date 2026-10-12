# v1 부하테스트

정상 트래픽 테스트는 API 사용자 흐름과 STOMP 채팅을 함께 실행한다. target은 t4g.small·2GiB, runner는 t4g.large이며 서비스 이미지는 v1.4.0으로 고정한다.

상세 분석: [Cloud-Dev-v1-Load-Test](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v1-Load-Test)

## 구성

```text
loadtest/v1/
├── README.md
├── normal/k6/   정상 API·채팅 시나리오(main.js, chat.js)
├── terraform/   공통 target·runner EC2와 보안 그룹
├── target/      공통 서비스 설정·시드·지표와 로그 수집
└── runner/      공통 k6 실행 환경·Prometheus·Loki·Grafana
```

| 프로필 | 기본 입력 |
| --- | --- |
| smoke | API 세션 3회, 채팅 10연결 |
| step | 0.5·1·2·3·4배, 단계마다 30초 증가 후 180초 유지 |
| breakpoint | 20분 동안 0 → 8배 증가 |

1배는 API 6.7세션/초와 채팅 300연결이다. API는 목록·상세 조회와 취향 등록·교환·수정·삭제·그룹 작업을 실행한다. 채팅은 40초마다 메시지를 보내고 10분 뒤 재연결한다. S3 업로드·카카오 로그인 전체 과정·AI 요청·프론트 페이지는 호출하지 않는다.

API 임계값은 p95 2초와 실패율 1%다. 실행 시작 1분 이후 누적 HTTP 실패율이 30%를 넘으면 중단한다. 설정값은 `normal/k6/main.js`의 환경변수로 조정한다.

## 준비

로컬에 Terraform, AWS 인증, SSH 키(`bakkucca-v1` 키 페어), GHCR 읽기 권한을 준비한다. 아래 로컬 명령은 CLOUD 레포 루트에서 실행한다. 기존 환경을 재사용할 때는 IP를 조회하고 파일·설정부터 확인한다. Terraform state는 `terraform/`에 유지한다.

```bash
terraform -chdir=loadtest/v1/terraform init
terraform -chdir=loadtest/v1/terraform apply
terraform -chdir=loadtest/v1/terraform output ip
```

`terraform output ip`에서 공인·사설 IP를 확인한다. 로컬 터미널에서 아래 두 공인 IP를 실제 값으로 바꿔 설정한다. 사설 IP는 각 원격 `.env`에 넣는다.

```bash
TARGET_PUBLIC_IP='<target-public-ip>'
RUNNER_PUBLIC_IP='<runner-public-ip>'
LOADTEST_SSH_KEY="$HOME/.ssh/bakkucca_v1"
```

target·runner 공인 IP에 파일을 복사한다.

```bash
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/target "ec2-user@$TARGET_PUBLIC_IP:~/"
scp -i "$LOADTEST_SSH_KEY" docker-compose.yml "ec2-user@$TARGET_PUBLIC_IP:~/target/"
scp -i "$LOADTEST_SSH_KEY" nginx/default.conf "ec2-user@$TARGET_PUBLIC_IP:~/target/nginx/"
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/runner "ec2-user@$RUNNER_PUBLIC_IP:~/"
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/normal "ec2-user@$RUNNER_PUBLIC_IP:~/"
```

runner에 SSH 접속해 Bash 터미널의 `~/runner`에서 `.env`를 만든다. `TARGET_IP`에는 target 사설 IP를 넣는다. runner를 먼저 기동한다.

```bash
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$RUNNER_PUBLIC_IP"
```

아래는 runner에서 실행한다. 최초 기동 때는 cloud-init 완료를 기다린다.

```bash
sudo cloud-init status --wait
cd ~/runner
cp .env.example .env
vi .env
docker compose up -d
docker compose ps
```

target의 `~/target`에서 `.env`를 만들고 `RUNNER_HOST`에 runner 사설 IP를 넣는다. 두 환경의 `JWT_SECRET`은 같아야 한다. `.env.example`의 값은 테스트 전용이다.

```bash
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP"
```

아래는 target에서 실행한다.

```bash
sudo cloud-init status --wait
cd ~/target
cp .env.example .env
vi .env
mkdir -p certs/live/bakkucca.com
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/CN=bakkucca.com" \
  -keyout certs/live/bakkucca.com/privkey.pem \
  -out certs/live/bakkucca.com/fullchain.pem
docker login ghcr.io
docker compose up -d --wait
docker compose ps
docker exec nginx nginx -t
curl -ksS https://127.0.0.1/health
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < seed.sql
```

기존 DB를 재사용할 때는 마지막 시드 입력 명령을 생략한다. 시드는 빈 DB에 한 번 넣는다. 기본 사용자 2,000명, 신규 사용자 1,000명, 그룹 120개, 물건 24,000개, 채팅방 1,000개를 생성한다.

## 정상 트래픽 테스트 실행

runner의 Bash 터미널에서 아래 블록을 실행한다. 첫 실행은 `PROFILE=smoke`로 확인한다. 통과 후 첫 줄을 `PROFILE=step`으로 바꿔 같은 블록을 실행하고, 연속 증가가 필요하면 `PROFILE=breakpoint`를 선택한다.

```bash
PROFILE=smoke
cd ~/runner
TESTID="${PROFILE}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p results
printf 'TESTID=%s\n' "$TESTID"
date -u +%FT%TZ > "results/$TESTID.start"
set -o pipefail
K6_SCRIPTS_DIR=../normal/k6 docker compose run --rm --no-deps --interactive=false --name "$TESTID" k6 run \
  -e PROFILE="$PROFILE" -e TESTID="$TESTID" \
  -e MULTIPLIERS="0.5 1 2 3 4" -e STEP_SECONDS=180 \
  --out experimental-prometheus-rw \
  --out "json=/results/$TESTID.metrics.json.gz" \
  main.js 2>&1 | tee "results/$TESTID.log"
K6_EXIT=${PIPESTATUS[0]}
date -u +%FT%TZ > "results/$TESTID.end"
printf '%s\n' "$K6_EXIT" > "results/$TESTID.exitcode"
```

실행 중 수동 중단이 필요하면 다른 runner 터미널에서 `docker kill --signal=SIGINT <TESTID>`를 실행한다. k6 정상 종료는 0, 임계값 실패·자동 중단·SIGINT는 별도 종료 코드로 남긴다. raw 지표와 요약을 함께 확인한다.

| 환경변수 | 기본값 | 설정 |
| --- | --- | --- |
| TESTID | 프로필과 실행 시각 | 결과 식별자 |
| PEAK_SESSIONS_PER_SEC | 6.7 | 1배 API 세션 시작률 |
| CHAT_CONNECTIONS | 300 | 1배 채팅 연결 수 |
| THINK_SECONDS | 1 | API 요청 사이 평균 대기 시간(초) |
| RAMP_SECONDS | 30 | step 증가 시간(초) |
| STEP_SECONDS | 180 | step 유지 시간(초) |
| BREAKPOINT_MAX | 8 | breakpoint 최대 배수 |
| BREAKPOINT_SECONDS | 1200 | breakpoint 전체 시간(초) |

## 결과

- `~/runner/results/<testid>.txt`: 구간별 요약
- `~/runner/results/<testid>.json`: k6 요약 지표
- `~/runner/results/<testid>.metrics.json.gz`: 요청별 raw 지표 포인트
- `~/runner/results/<testid>.log`, `.start`, `.end`, `.exitcode`: 콘솔·UTC 실행 구간·종료 코드
- Prometheus: k6·호스트·컨테이너·서비스 지표
- Loki: 컨테이너·Nginx 처리 시간·커널 로그
- Grafana: `부하 테스트 - v1 운영 복제` 대시보드

로컬에서 Grafana 터널을 열고 `http://localhost:3000`에 접속한다. 조회는 익명으로 가능하고 기본 관리자 계정은 `admin / admin`이다. 테스트 ID와 실행 시간으로 결과를 조회한다.

```bash
ssh -i "$LOADTEST_SSH_KEY" -N -L 3000:127.0.0.1:3000 "ec2-user@$RUNNER_PUBLIC_IP"
```

요약의 채팅 연결 수는 목표값이다. 구간별 누락 세션 0만으로 누락이 없다고 판정하지 않고 전체 JSON과 대시보드를 함께 확인한다. 일부 409·404는 예상 응답으로 집계한다.

## 결과 수집

실행이 끝나면 runner의 결과 파일을 로컬 CLOUD 레포에 복사한다. `TESTID`는 실행할 때 출력된 값을 사용한다.

```bash
TESTID='<testid>'
RESULT_DIR="loadtest/v1/runner/results/$TESTID"
mkdir -p "$RESULT_DIR"
scp -i "$LOADTEST_SSH_KEY" \
  "ec2-user@$RUNNER_PUBLIC_IP:~/runner/results/$TESTID.*" "$RESULT_DIR/"
```

결과에는 구간별 요약, k6 지표, 콘솔 로그, 시작·종료 시각, 종료 코드가 포함된다. Prometheus와 Loki 데이터는 runner에서 확인하고, Grafana 대시보드에서 같은 TESTID와 실행 시간 구간을 선택한다.

## 데이터 초기화와 환경 삭제

같은 시드로 정상 테스트를 반복할 때는 target의 데이터 볼륨을 초기화하고 시드를 다시 입력한다. 이 명령은 target의 테스트 데이터를 삭제한다.

```bash
cd ~/target
docker compose down -v
docker compose up -d --wait
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < seed.sql
```

환경을 삭제하기 전 runner 결과와 필요한 Prometheus·Loki 데이터를 로컬에 보관한다. 아래 명령은 로컬 CLOUD 레포 루트에서 실행한다.

```bash
terraform -chdir=loadtest/v1/terraform destroy
```
