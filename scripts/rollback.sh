#!/usr/bin/env bash
#
# 직전 안정 버전(previous) 원자적 롤백 스크립트
#
# 종료 코드:
#   0: 롤백 및 정상 가동 검증 성공
#   1: 롤백 대상 부재 또는 컨테이너 기동/검증 실패
#
set -uo pipefail

PROJECT_ROOT="/opt/app"
log() { echo "[$(date '+%H:%M:%S')] [ROLLBACK] $*"; }

log "직전 안정 버전(previous) 확인 중..."

if [[ ! -L "${PROJECT_ROOT}/previous" ]] || [[ ! -e "${PROJECT_ROOT}/previous" ]]; then
  log "[FATAL] 롤백할 직전 버전(previous) 심볼릭 링크가 존재하지 않거나 대상 폴더가 유실되었습니다!"
  exit 1
fi

PREV_DIR=$(readlink -f "${PROJECT_ROOT}/previous")
PREV_VER=$(basename "$PREV_DIR")
log "복구 대상 버전 확정: ${PREV_VER} (${PREV_DIR})"

# current 심볼릭 링크를 previous 대상으로 원자적 교체
ln -sfn "$PREV_DIR" "${PROJECT_ROOT}/current_tmp"
mv -Tf "${PROJECT_ROOT}/current_tmp" "${PROJECT_ROOT}/current"
log "current 심볼릭 링크가 ${PREV_VER} 디렉터리로 복구되었습니다."

# 직전 안정 버전 컨테이너 구동 (이미 로컬 캐시에 존재하므로 즉시 기동)
cd "$PREV_DIR"
if ! docker compose -p bakkucca up -d --no-deps --wait springboot fastapi nextjs; then
  log "[FATAL] 직전 컨테이너 기동 실패! 컨테이너 상태를 확인하세요."
  docker compose -p bakkucca ps -a
  exit 1
fi

# Nginx 업스트림 DNS 리로드
docker compose -p bakkucca exec -T nginx nginx -s reload || true

# 롤백된 버전의 정상 가동 상태 재검증
log "롤백 버전 정상 동작 여부 검증 중..."
if ! "${PROJECT_ROOT}/scripts/verify.sh"; then
  log "[FATAL] 롤백 후 검증 실패! 긴급 수동 개입이 필요합니다."
  exit 1
fi

log "[SUCCESS] 직전 안정 버전(${PREV_VER})으로 롤백 및 가용성 복구가 완료되었습니다."
exit 0