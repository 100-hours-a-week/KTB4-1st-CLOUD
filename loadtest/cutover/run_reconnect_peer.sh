#!/usr/bin/env bash
# 별도 시험 EC2에서 사용. AWS/CloudFront 설정을 변경하지 않는다.
set +x
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
: "${RUN_ID:?새 RUN_ID 필요}"
: "${FIXTURE_FILE:?별도 PubSub fixture 경로 필요}"
FIXTURE_JSON=$(cat "$FIXTURE_FILE")
[[ "$RUN_ID" =~ ^[a-z0-9]{1,10}$ ]] || exit 1
[[ ! -e "results/$RUN_ID" ]] || { echo 'RUN_ID 재사용 금지'; exit 1; }
JWT_SECRET=$(sudo docker inspect springboot --format '{{json .Config.Env}}' | python3 -c '
import json,sys
v=dict(x.split("=",1) for x in json.load(sys.stdin)); s=v.get("JWT_SECRET","")
if not v.get("DB_URL", "").startswith("jdbc:mysql://bakkucca-v2-staging-mysql.c9acsiyqqzik.ap-northeast-2.rds.amazonaws.com:3306/market"):
    sys.exit("staging DB 대상이 아니므로 시험 토큰 발급 중단")
if len(s)<32: sys.exit("JWT_SECRET 확인 필요")
print(s)
')
export JWT_SECRET RUN_ID FIXTURE_JSON
mkdir -p "results/$RUN_ID"
sudo --preserve-env=JWT_SECRET,RUN_ID,FIXTURE_JSON docker run --rm --network host \
  --user "$(id -u):$(id -g)" -e JWT_SECRET -e RUN_ID -e FIXTURE_JSON \
  -e RESULTS_DIR=/results \
  -v "$PWD/loadtest:/scripts:ro" -v "$PWD/results/$RUN_ID:/results" \
  grafana/k6:1.3.0 run --log-format raw \
  --console-output "/results/$RUN_ID-ledger.jsonl" /scripts/cutover/reconnect_peer.js
