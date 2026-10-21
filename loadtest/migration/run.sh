#!/usr/bin/env bash
# 마이그레이션용 EC2에서 API·채팅 부하를 실행하고 결과를 저장한다.
set +x
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir/../.."

sudo -v
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
CHAT_ORIGIN=$(printf '%s' "$backend_env" | python3 -c '
import json, sys
values = dict(v.split("=", 1) for v in json.load(sys.stdin))
origins = values.get("CORS_ALLOWED_ORIGINS", "").split(",")
origin = next((v.strip() for v in origins if v.strip().startswith("https://")), "")
if not origin:
    sys.exit("시험 BE의 CORS_ALLOWED_ORIGINS에 HTTPS Origin이 필요합니다.")
print(origin)
')
unset backend_env

RUN_ID=$(openssl rand -hex 5)
export JWT_SECRET CHAT_ORIGIN RUN_ID
sudo install -d -o "$(id -u)" -g "$(id -g)" "results/$RUN_ID"
printf '시험 ID: %s\n결과 폴더: %s/results/%s\n' "$RUN_ID" "$PWD" "$RUN_ID"

# Ctrl+C 종료만 별도 기록한다. 오류나 강제 종료를 정상 결과로 숨기지 않는다.
manual_stop=false
trap 'manual_stop=true; printf "\n수동 종료 요청: 저장된 결과를 확인합니다.\n"' INT
set +e

# JWT 키를 명령행 인자로 노출하지 않고 k6에 전달한다.
sudo --preserve-env=JWT_SECRET,CHAT_ORIGIN,RUN_ID docker run --rm \
  --network host --user "$(id -u):$(id -g)" \
  -e JWT_SECRET -e CHAT_ORIGIN -e RUN_ID -e BASE_URL=https://127.0.0.1/api \
  -e RATE=1 -e MINUTES=30 -e WRITE_SESSIONS=10 \
  -e CHAT_PAIRS=2 -e CHAT_HOLD_SECONDS=60 -e CHAT_INTERVAL_SECONDS=5 \
  -e SELF_SIGNED=true -e RESULTS_DIR=/results \
  -v "$PWD/loadtest/migration:/scripts:ro" -v "$PWD/results/$RUN_ID:/results" \
  grafana/k6:1.3.0 run --log-format raw \
  --console-output "/results/$RUN_ID-ledger.jsonl" /scripts/traffic.js

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
