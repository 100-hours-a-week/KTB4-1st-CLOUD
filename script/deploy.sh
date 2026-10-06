#!/usr/bin/env bash
# 운영 EC2에서 deploy.yml이 SSH로 실행하는 배포 스크립트
#
# 사용법: deploy.sh <배포할 버전> [롤백 후보 버전 ...]
#   - deploy.yml이 이 스크립트와 함께 ~/bakkucca 에 올려 보내는 파일
#       docker-compose.yml, nginx/default.conf
#       base.env                 ENV_FILE 시크릿(비밀값)
#       releases/<버전>.env       Release Bundle의 이미지(NEXTJS_IMAGE 등 3줄)
#   - 롤백 후보: main의 Release Bundle 중 배포 버전보다 낮은 버전, 내림차순 최대 4개
#
# 흐름
#   이미지 pull → 컨테이너 교체 → 검증(컨테이너 헬스체크, Nginx 경유 5XX 확인)
#   → 실패하면 롤백 후보를 순서대로 같은 방식으로 시도
#
# 종료 코드
#   0 배포 성공
#   1 배포 실패, 롤백 성공
#   2 배포 실패, 롤백도 모두 실패 (수동 대응 필요)
#   3 배포할 버전의 이미지 pull 실패 (운영 중인 컨테이너는 변경하지 않음)
set -uo pipefail
cd "$(dirname "$0")" || exit 3
chmod 600 base.env
trap 'rm -f .env.next' EXIT

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 버전의 이미지를 먼저 받는다. 실패하면 .env와 컨테이너는 그대로 둔다.
pull_version() {
  (umask 077 && cat base.env "releases/$1.env" > .env.next)
  if ! docker compose --env-file .env.next pull --quiet; then
    log "$1 이미지 pull 실패"
    return 1
  fi
}

# Nginx(443)를 거쳐 FE, BE로 요청. 5XX나 연결 실패면 실패
check_nginx() {
  local path code
  for path in / /api/actuator/health/readiness; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1${path}")
    if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
      log "Nginx 경유 요청 실패: ${path} → ${code}"
      return 1
    fi
  done
  log "Nginx 경유 요청 통과"
}

# 받은 이미지로 교체하고 검증한다. 설정이 바뀐 컨테이너만 다시 만들어진다.
switch_and_verify() {
  mv .env.next .env
  # compose 헬스체크(BE는 actuator readiness)가 모두 healthy가 될 때까지 대기
  if ! docker compose up -d --wait; then
    log "컨테이너 헬스체크 실패"
    docker compose ps -a
    return 1
  fi
  # nginx는 설정 파일 내용이 바뀌어도 compose가 알아채지 못하므로 매번 다시 만든다
  docker compose up -d --wait --no-deps --force-recreate nginx || return 1
  check_nginx
}

target="$1"
shift
log "배포 시작: ${target} (롤백 후보: ${*:-없음})"

if ! pull_version "$target"; then
  log "운영 중인 컨테이너는 변경하지 않았습니다."
  exit 3
fi

if switch_and_verify; then
  log "배포 성공: ${target}"
  exit 0
fi

log "배포 검증 실패: ${target}"
for version in "$@"; do
  log "롤백 시도: ${version}"
  if pull_version "$version" && switch_and_verify; then
    log "롤백 성공: ${version}"
    exit 1
  fi
done

log "롤백 실패. 수동 대응이 필요합니다."
exit 2
