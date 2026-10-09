#!/usr/bin/env bash
#
# /opt/app/scripts/verify.sh
# Nginx(443) 프록시 경유 E2E 스모크 테스트 전담 스크립트
#
# 검증 대상:
#   1. Next.js 메인 페이지 (HTML 200 OK)
#   2. Spring Boot -> MySQL 읽기 경로 (/api/v1/health/ping/mysql -> SELECT 1)
#   3. Spring Boot -> FastAPI 중계 경로 (/api/v1/health/ping/fastapi)
#
set -uo pipefail

log() { echo "[$(date '+%H:%M:%S')] [E2E-VERIFY] $*"; }

log "E2E 스모크 테스트 게이트 시작 (Nginx 443 경유)"

# -----------------------------------------------------------------------------
# 1. Next.js 프론트엔드 메인 응답 검증
# -----------------------------------------------------------------------------
log "1. Next.js 메인 페이지 HTTP 응답 확인 (/)"
FE_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1/" || echo "000")
if [[ "$FE_CODE" != "200" ]]; then
  log "[FAIL] Next.js 메인 페이지 응답 실패 (HTTP 상태 코드: ${FE_CODE})"
  exit 1
fi
log "  - Next.js 정상 응답 (HTTP 200)"

# -----------------------------------------------------------------------------
# 2. Spring Boot -> MySQL 연동 검증
# -----------------------------------------------------------------------------
log "2. Spring Boot -> MySQL 연동 상태 확인 (/api/health/ping/mysql)"
MYSQL_RES=$(curl -sk --max-time 5 "https://127.0.0.1/api/health/ping/mysql" || echo "{}")
MYSQL_STATUS=$(echo "$MYSQL_RES" | grep -o '"status":"UP"' || true)

if [[ "$MYSQL_STATUS" != '"status":"UP"' ]]; then
  log "[FAIL] MySQL 헬스 엔드포인트 응답 실패. 응답 내용: ${MYSQL_RES}"
  exit 1
fi
log "  - MySQL DB 커넥션 및 쿼리 응답 정상 (UP)"

# -----------------------------------------------------------------------------
# 3. Spring Boot -> FastAPI 프록시 중계 검증
# -----------------------------------------------------------------------------
log "3. Spring Boot -> FastAPI 중계 상태 확인 (/api/health/ping/fastapi)"
AI_RES=$(curl -sk --max-time 5 "https://127.0.0.1/api/health/ping/fastapi" || echo "{}")
AI_STATUS=$(echo "$AI_RES" | grep -o '"status":"UP"' || true)

if [[ "$AI_STATUS" != '"status":"UP"' ]]; then
  log "[FAIL] FastAPI 프록시 헬스 엔드포인트 응답 실패. 응답 내용: ${AI_RES}"
  exit 1
fi
log "  - FastAPI 중계 통신 정상 (UP)"

log "[SUCCESS] 모든 E2E 스모크 테스트 게이트를 통과했습니다."
exit 0