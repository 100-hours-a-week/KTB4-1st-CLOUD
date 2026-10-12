# v1 부하테스트

이 디렉터리는 정상 트래픽 부하테스트와 단일 계정 반복 요청의 rate limit 검증을 포함한다. 정상 시나리오는 API 사용자 흐름과 STOMP 채팅을 함께 실행한다. target은 t4g.small·2GiB, runner는 t4g.large이며 서비스 이미지는 v1.4.0으로 고정한다.

상세 분석: [Cloud-Dev-v1-Load-Test](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-v1-Load-Test)

## 구성

```text
loadtest/v1/
├── README.md
├── normal/k6/   정상 API·채팅 시나리오(main.js, chat.js)
├── attack/      단일 계정 반복 시나리오·사용자별 Nginx 제한
│   ├── k6/group-repeat.js
│   ├── docker-compose.rate-limit.yml
│   └── nginx/
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

## 공격자 반복 요청의 P0/P1 재현

정상 테스트와 같은 runner·target을 사용한다. 계정은 `sub=1` 하나, API는 `POST /api/groups`, 본문은 기존 그룹명으로 고정한다. 각 VU는 응답을 기다린 뒤 즉시 반복한다. 입력은 **30초 동안 1 → 800 VU, 이후 4분 30초 유지**, HTTP timeout 65초다. VU는 동일 계정의 병렬 반복 수다.

### 1. 파일과 검증 키 준비

로컬 CLOUD 레포 루트에서 `attack/`을 두 인스턴스의 `~/attack`으로 복사한다. 공통 runner·target은 앞의 준비 절차를 사용한다.

```bash
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/attack "ec2-user@$RUNNER_PUBLIC_IP:~/"
scp -r -i "$LOADTEST_SSH_KEY" loadtest/v1/attack "ec2-user@$TARGET_PUBLIC_IP:~/"
```

target의 `~/target`에서 실행 중인 BE의 테스트 JWT 키를 비공개 파일로 만든다. 값은 출력하지 않는다. 이 작업은 초기 준비 또는 테스트 키 변경 때 수행한다.

```bash
cd ~/target
sudo python3 - <<'PY'
from pathlib import Path
import json, os, subprocess

env = json.loads(subprocess.check_output(
    ['docker', 'inspect', 'springboot', '--format', '{{json .Config.Env}}'], text=True))
key = next(value.partition('=')[2] for value in env if value.startswith('JWT_SECRET='))
assert len(key.encode()) >= 32
uid = int(subprocess.check_output(['docker', 'exec', 'nginx', 'id', '-u', 'nginx']))
gid = int(subprocess.check_output(['docker', 'exec', 'nginx', 'id', '-g', 'nginx']))
path = Path('../attack/nginx/jwt.secret')
path.write_bytes(key.encode())
os.chown(path, uid, gid)
os.chmod(path, 0o400)
PY
```

runner `.env`의 JWT 키도 같은 값이어야 한다. 정상 시나리오는 `K6_SCRIPTS_DIR=../normal/k6`, 공격자 반복은 `K6_SCRIPTS_DIR=../attack/k6`로 스크립트 디렉터리를 선택한다. 기본값은 정상 시나리오다. P1은 기존 Nginx 이미지의 njs 모듈을 사용하므로 아래 `nginx -t`를 통과한 구성으로 실행한다.

### 2. P0: 제한 없는 구성

P0·P1은 각각 시작 전에 **복제 target을 재부팅하고 서비스가 healthy인 상태**로 맞춘다. DB·시드·이미지·메모리 한도는 바꾸지 않는다. 재부팅으로 SSH 연결이 종료되면 재접속한다.

```bash
sudo reboot
```

target에 재접속한 뒤 `~/target`에서 P0를 적용한다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --wait
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml \
  up -d --no-deps --force-recreate nginx
docker exec nginx nginx -t
docker compose ps
curl -ksS https://127.0.0.1/health
docker inspect nginx --format 'id={{.Id}} image={{.Image}} memory={{.HostConfig.Memory}}'
pid=$(docker inspect nginx --format '{{.State.Pid}}')
cg=$(awk -F: '$1=="0" {print $3}' "/proc/$pid/cgroup")
cat "/sys/fs/cgroup$cg/memory.events"
```

시작 전에 `memory=67108864`(64MiB), `oom=0`, `oom_kill=0`, health 200을 확인한다. runner에서 다음 블록의 `PHASE=p0`로 실행한다. 아래 3번 관측은 별도 로컬 터미널에서 동시에 시작한다.

```bash
PHASE=p0
cd ~/runner
TESTID="${PHASE}-$(date -u +%Y%m%dT%H%M%SZ)-800vu"
mkdir -p results
printf 'TESTID=%s\n' "$TESTID"
sha256sum ../attack/k6/group-repeat.js > "results/$TESTID.script.sha256"
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

### 3. OOM 관측과 중단

별도 **로컬 터미널**에서 공인 IP·SSH 키 변수를 위 준비 단계와 같이 설정하고, runner에 출력된 TESTID를 넣는다. cgroup을 호스트에서 조회하며 최초 `oom_kill > 0`을 관측하면 해당 k6 컨테이너에 SIGINT를 보낸다. runner의 종료 파일이 생기면 관측도 끝난다. P1에도 같은 관측을 사용한다.

```bash
TESTID='<runner에 출력된 TESTID>'
RESULT_DIR="loadtest/v1/runner/results/$TESTID"
mkdir -p "$RESULT_DIR"
while true; do
  if SAMPLE=$(ssh -i "$LOADTEST_SSH_KEY" -o ConnectTimeout=10 \
    "ec2-user@$TARGET_PUBLIC_IP" '
      date -u +%FT%TZ
      pid=$(docker inspect nginx --format "{{.State.Pid}}")
      cg=$(awk -F: '\''$1=="0" {print $3}'\'' "/proc/$pid/cgroup")
      cat "/sys/fs/cgroup$cg/memory.current"
      cat "/sys/fs/cgroup$cg/memory.events"
    '); then
    printf '%s\n' "$SAMPLE" | tee -a "$RESULT_DIR/monitor.log"
    OOM_KILLS=$(printf '%s\n' "$SAMPLE" | awk '$1=="oom_kill" {print $2}')
    if [ "${OOM_KILLS:-0}" -gt 0 ]; then
      ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$RUNNER_PUBLIC_IP" \
        "docker kill --signal=SIGINT '$TESTID'"
      break
    fi
  fi
  if ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$RUNNER_PUBLIC_IP" \
    "test -f ~/runner/results/$TESTID.end"; then
    break
  fi
  sleep 2
done
```

SSH나 지표 수집이 지연되면 수집 간격도 늘어난다. OOM의 정확한 시각과 원인은 아래 커널 로그로 확인한다. worker OOM은 Docker 재시작 횟수 0이어도 발생할 수 있다.

### 4. P1: 사용자별 제한 적용

**P0 결과를 아래 수집 절차로 먼저 보관한 뒤** target을 재부팅한다. 재접속 후 P1을 적용한다. DB 볼륨은 삭제하지 않는다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --wait
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml \
  -f ../attack/docker-compose.rate-limit.yml up -d --no-deps --force-recreate nginx
docker exec nginx nginx -t
docker compose ps
curl -ksS https://127.0.0.1/health
docker inspect nginx --format 'id={{.Id}} image={{.Image}} memory={{.HostConfig.Memory}}'
pid=$(docker inspect nginx --format '{{.State.Pid}}')
cg=$(awk -F: '$1=="0" {print $3}' "/proc/$pid/cgroup")
cat "/sys/fs/cgroup$cg/memory.events"
```

P0와 이미지·64MiB 한도가 같고 OOM 카운터가 0인지 확인한다. runner에서 2번 실행 블록의 첫 줄만 **`PHASE=p1`**로 바꿔 동일 단계로 실행한다. 관측 터미널에도 새 TESTID를 넣는다. P1은 검증된 JWT 사용자 ID별 1요청/초·burst 5·nodelay·초과 429이며, OOM 없이 5분 정상 종료하는지 확인한다.

## 실행 결과 수집

각 실행 직후, target을 재부팅하거나 Nginx를 재생성하기 **전에** 수집한다. 정상 테스트에도 같은 절차를 사용한다. 로컬 CLOUD 레포 루트에서 해당 TESTID를 설정한다.

```bash
TESTID='<수집할 TESTID>'
RESULT_DIR="loadtest/v1/runner/results/$TESTID"
mkdir -p "$RESULT_DIR"
scp -i "$LOADTEST_SSH_KEY" \
  "ec2-user@$RUNNER_PUBLIC_IP:~/runner/results/$TESTID.*" "$RESULT_DIR/"
START_UTC=$(cat "$RESULT_DIR/$TESTID.start")
END_UTC=$(cat "$RESULT_DIR/$TESTID.end")
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP" \
  "docker logs --since '$START_UTC' --until '$END_UTC' nginx 2>&1" \
  > "$RESULT_DIR/nginx.log"
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP" \
  bash -s -- "$START_UTC" "$END_UTC" <<'SH' > "$RESULT_DIR/kernel.log"
start=$(date -u -d "$1" '+%F %T UTC')
end=$(date -u -d "$2" '+%F %T UTC')
sudo journalctl -k -b --since "$start" --until "$end" --no-pager -o short-iso-precise
SH
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP" '
  date -u +%FT%TZ
  docker ps --format "{{.Names}} {{.Status}}"
  docker inspect nginx --format "id={{.Id}} image={{.Image}} memory={{.HostConfig.Memory}} restart={{.RestartCount}} OOMKilled={{.State.OOMKilled}}"
  pid=$(docker inspect nginx --format "{{.State.Pid}}")
  cg=$(awk -F: '\''$1=="0" {print $3}'\'' "/proc/$pid/cgroup")
  cat "/sys/fs/cgroup$cg/memory.current"
  cat "/sys/fs/cgroup$cg/memory.events"
  cat "/sys/fs/cgroup$cg/memory.stat"
  free -m
  cat /proc/pressure/memory /proc/pressure/io
' > "$RESULT_DIR/after.txt"
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP" \
  'docker exec nginx cat /var/log/nginx-timing/access.json' \
  | gzip > "$RESULT_DIR/nginx-timing.jsonl.gz"
ssh -i "$LOADTEST_SSH_KEY" "ec2-user@$TARGET_PUBLIC_IP" \
  'docker exec nginx nginx -T 2>&1' > "$RESULT_DIR/nginx-config.txt"
```

timing 파일에는 같은 Nginx 볼륨의 이전 실행도 포함될 수 있으므로 start/end로 필터링한다. Docker stdout/stderr는 회전될 수 있어 전체 요청 수는 raw k6 포인트와 timing을 대조한다. 이미 재부팅했다면 커널 수집 명령의 `-b`를 `-b -1`로 바꾸고 해당 실행의 부팅·시간을 확인한다. 재생성한 cgroup의 카운터를 이전 실행의 카운터로 사용하지 않는다.

정상 테스트의 `.json`은 요약이고 `.metrics.json.gz`는 지표 포인트 스트림이다. 단일 계정 반복은 요약 파일 대신 raw 포인트를 사용한다. `http_req_duration` 포인트의 상태별 건수·완료 시각, Nginx의 `upstream`과 P1의 `limit=REJECTED`를 대조한다. 지표 시계열은 Prometheus, 추가 로그는 Loki에서 같은 UTC 구간으로 조회한다.

### 비교 기준과 기존 실측

| 확인 항목 | P0 | P1 |
| --- | --- | --- |
| 입력 | 계정 1 · 동일 API·본문 · 최대 800 VU | 동일 |
| Nginx 메모리 제한 | 64MiB | 동일 |
| 종료 조건 | 최초 worker OOM에서 중단 | OOM 없이 5분 정상 종료 |
| 초과 요청 | 백엔드로 전달 | 429, upstream 미전달 |

2026-10-12의 3차 실측에서는 P0가 OOM 전 10,640건 모두 409를 응답한 뒤 약 97초에 worker OOM 1회가 발생했다. P1은 5분 동안 306건 전달·1,158,253건 차단, OOM·예상 밖 오류 0건이었다. 다음 실행은 새 TESTID로 실제 결과를 확인한다. 10,640건은 고정 OOM 임계 요청 수가 아니다.

409는 중복 그룹명 업무 오류이고 429는 의도적 차단이다. 상태 0·5xx와 별도로 집계한다. P0의 OOM 이후 중단된 요청도 실패 지표에 포함되므로 OOM 전후를 나눈다. 응답 속도에 따라 실제 반복 수가 달라져 동일 RPS 비교는 아니며, 전달량 감소율은 같은 시간 구간으로 계산한다.

## 초기화·롤백·삭제

사용자별 제한을 제거하려면 target에서 P0의 두 Compose 파일로 Nginx만 재생성한다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml \
  up -d --no-deps --force-recreate nginx
docker exec nginx nginx -t
```

정상 테스트를 같은 시드로 다시 시작할 때만 target의 데이터 볼륨을 초기화한다. P0/P1 비교 사이에는 실행하지 않는다.

```bash
cd ~/target
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml down -v
docker compose -f docker-compose.yml -f docker-compose.loadtest.yml up -d --wait
docker compose exec -T mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < seed.sql
```

테스트 환경을 삭제하기 전에 결과 파일을 받고, 필요한 Prometheus/Loki/Grafana 데이터를 보관한다. 아래 명령은 로컬에서 실행한다.

```bash
terraform -chdir=loadtest/v1/terraform destroy
```
