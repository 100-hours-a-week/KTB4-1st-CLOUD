#!/usr/bin/env bash
# 별도 전환 시험 EC2에서 API·채팅 부하를 실행하고 결과를 저장한다.
set +x
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir/../.."

# 별도 fixture의 소유권·미사용 상태를 읽기 전용으로 확인한 후에만 실행한다.
: "${FIXTURE_FILE:?전환 시험용 fixture JSON 파일이 필요합니다}"
: "${FIXTURE_REVIEWED_RUN:?RUN_ID와 같은 값으로 fixture 검토를 확인하세요}"
: "${RUN_ID:?새 RUN_ID가 필요합니다}"
[[ "$FIXTURE_REVIEWED_RUN" == "$RUN_ID" ]] || { echo 'fixture 검토 RUN_ID 불일치'; exit 1; }
CHAT_ENABLED=${CHAT_ENABLED:-false}
[[ "$CHAT_ENABLED" == true || "$CHAT_ENABLED" == false ]] || { echo 'CHAT_ENABLED: true 또는 false'; exit 1; }
export CHAT_ENABLED
FIXTURE_JSON=$(python3 loadtest/cutover/fixture.py "$FIXTURE_FILE")
export FIXTURE_JSON

# 실제 사용하는 Docker 명령의 실행 권한을 확인
sudo -n docker info >/dev/null
backend_env=$(sudo docker inspect springboot --format '{{json .Config.Env}}')

# 실행 중인 시험 BE의 인증 키와 허용 Origin을 사용한다.
JWT_SECRET=$(printf '%s' "$backend_env" | python3 -c '
import json, sys
values = dict(v.split("=", 1) for v in json.load(sys.stdin))
key = values.get("JWT_SECRET", "")
if len(key) < 32:
    sys.exit("시험 BE의 JWT_SECRET을 확인하세요.")
print(key)
')
CHAT_ORIGIN=${CHAT_ORIGIN:-$(printf '%s' "$backend_env" | python3 -c '
import json, sys
values = dict(v.split("=", 1) for v in json.load(sys.stdin))
origins = values.get("CORS_ALLOWED_ORIGINS", "").split(",")
origin = next((v.strip() for v in origins if v.strip().startswith("https://")), "")
if not origin:
    sys.exit("시험 BE의 CORS_ALLOWED_ORIGINS에 HTTPS Origin이 필요합니다.")
print(origin)
')}
unset backend_env

RUN_ID=${RUN_ID:-$(openssl rand -hex 5)}
[[ "$RUN_ID" =~ ^[a-z0-9]{1,10}$ ]] || { echo 'RUN_ID: 영문 소문자·숫자 1~10자'; exit 1; }
script=cutover/traffic.js
BASE_URL=https://staging.bakkucca.com/api
CHAT_ORIGIN=https://staging.bakkucca.com
SELF_SIGNED=false
export JWT_SECRET CHAT_ORIGIN RUN_ID
[[ ! -e "results/$RUN_ID" ]] || { echo '이미 존재하는 RUN_ID입니다. 새 ID를 사용하세요.'; exit 1; }
sudo install -d -o "$(id -u)" -g "$(id -g)" "results/$RUN_ID"
printf '시험 ID: %s\n결과 폴더: %s/results/%s\n' "$RUN_ID" "$PWD" "$RUN_ID"

# Ctrl+C 종료만 별도 기록한다. 오류나 강제 종료를 정상 결과로 숨기지 않는다.
manual_stop=false
trap 'manual_stop=true; printf "\n수동 종료 요청: 저장된 결과를 확인합니다.\n"' INT
set +e

# JWT 키를 명령행 인자로 노출하지 않고 k6에 전달한다.
sudo --preserve-env=JWT_SECRET,CHAT_ORIGIN,RUN_ID,FIXTURE_JSON docker run --rm \
  --network host --user "$(id -u):$(id -g)" \
  -e FIXTURE_JSON -e JWT_SECRET -e CHAT_ORIGIN -e RUN_ID -e BASE_URL="${BASE_URL:-https://127.0.0.1/api}" \
  -e CHAT_ENABLED="$CHAT_ENABLED" \
  -e RATE="${RATE:-1}" -e MINUTES="${MINUTES:-30}" -e WRITE_SESSIONS="$(printf '%s' "$FIXTURE_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"]))')" \
  -e CHAT_PAIRS=2 -e CHAT_HOLD_SECONDS=60 -e CHAT_INTERVAL_SECONDS=5 \
  -e SELF_SIGNED="${SELF_SIGNED:-true}" -e RESULTS_DIR=/results \
  -e SPLIT_DELAY_SECONDS="${SPLIT_DELAY_SECONDS:-300}" \
  -e LONG_REQUEST_PATH="${LONG_REQUEST_PATH:-}" -e LONG_REQUEST_MIN_MS="${LONG_REQUEST_MIN_MS:-3000}" \
  -v "$PWD/loadtest:/scripts:ro" -v "$PWD/results/$RUN_ID:/results" \
  grafana/k6:1.3.0 run --log-format raw \
  --console-output "/results/$RUN_ID-ledger.jsonl" "/scripts/$script"

run_status=$?
set -e
trap - INT
if [[ "$manual_stop" == true && ( "$run_status" == 105 || "$run_status" == 130 ) ]]; then
  python3 - "$RUN_ID" "$run_status" <<'PY_STOP'
import json, pathlib, sys
run, status = sys.argv[1:]
folder = pathlib.Path('results') / run
if not (folder / f'{run}-summary.json').is_file():
    sys.exit('집계 파일이 없어 수동 종료 결과를 검증할 수 없습니다.')
(folder / f'{run}-stop.json').write_text(json.dumps({
    'run': run, 'reason': 'user_interrupt', 'exit_code': int(status)
}))
PY_STOP
  printf '수동 종료 결과 저장 완료. DB 대조 시 실행한 요청만 검증합니다.\n'
  exit 0
fi
exit "$run_status"
