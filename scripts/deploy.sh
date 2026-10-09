#!/usr/bin/env bash
#
# 운영 EC2 In-Place 무중단 배포 오케스트레이션 스크립트
#
# 사용법: deploy.sh <배포할 버전(예: v2.0.0)>
#
# 종료 코드:
#   0: 배포 및 3단계 로컬 검증 성공
#   1: 신규 배포 실패 -> 직전 안정 버전(previous) 롤백 성공
#   2: 신규 배포 실패 -> 직전 버전 롤백 실패 (긴급 수동 대응 필요)
#   3: 신규 이미지 Pull 실패 (운영 중인 컨테이너 무변경 상태 유지)
#
set -uo pipefail

PROJECT_ROOT="/opt/app"
TARGET_VERSION="${1:-}"

log() { echo "[$(date '+%H:%M:%S')] [DEPLOY] $*"; }

# 입력값 및 기본 디렉터리 검증
if [[ -z "$TARGET_VERSION" ]]; then
  log "[ERROR] 배포 대상 버전이 지정되지 않았습니다. (사용법: $0 <version>)"
  exit 3
fi

RELEASE_DIR="${PROJECT_ROOT}/releases/${TARGET_VERSION}"
SHARED_ENV="${PROJECT_ROOT}/shared/.env.shared"

if [[ ! -d "$RELEASE_DIR" ]]; then
  log "[ERROR] 릴리즈 디렉터리가 존재하지 않습니다: ${RELEASE_DIR}"
  exit 3
fi

if [[ ! -f "$SHARED_ENV" ]]; then
  log "[ERROR] 공유 환경변수 파일이 존재하지 않습니다: ${SHARED_ENV}"
  exit 3
fi

# 롤백 위임 함수
trigger_rollback() {
  log "[FAIL] 배포 단계 중 오류 감지. rollback.sh를 호출합니다..."
  if "${PROJECT_ROOT}/scripts/rollback.sh"; then
    log "[RECOVERED] 배포는 실패했으나 직전 안정 버전(previous)으로 안전하게 롤백되었습니다."
    exit 1
  else
    log "[CRITICAL] 배포 실패 및 직전 버전 롤백 복구까지 모두 실패했습니다!"
    exit 2
  fi
}

# =============================================================================
# 메인 배포 파이프라인
# =============================================================================
log "배포 프로세스 시작: ${TARGET_VERSION}"

# [Step 1] 환경 변수 스냅샷 생성 및 권한 제한
log "[1/5] 환경 변수 스냅샷 생성 (.env.shared + .env.release)"
(
  umask 077
  cat "$SHARED_ENV" "${RELEASE_DIR}/.env.release" > "${RELEASE_DIR}/.env"
  chmod 600 "${RELEASE_DIR}/.env"
)


# [Step 2] 신규 이미지 Pre-flight Pull (실패 시 운영 컨테이너 무변경 유지)
log "[2/5] 신규 도커 이미지 사전 Pull 검증"
cd "$RELEASE_DIR"
if ! docker compose -p bakkucca pull springboot fastapi nextjs; then
  log "[ABORT] 신규 이미지 pull 실패. 현재 운영 중인 컨테이너는 일체 변경하지 않았습니다."
  exit 3
fi


# [Step 3] 1단계 검증: 컨테이너 In-Place 교체 및 CLI 대기 (--wait)
log "[3/5] 컨테이너 갱신 및 Healthcheck 기동 대기"
if ! docker compose -p bakkucca up -d --no-deps --wait springboot fastapi nextjs; then
  log "[FAIL] 컨테이너 기동 및 헬스체크 대기 실패"
  docker compose -p bakkucca ps -a
  trigger_rollback
fi


# [Step 4] Nginx 업스트림 DNS 리로드 및 2~3단계 검증 (verify.sh 호출)
log "[4/5] Nginx 리로드 및 애플리케이션 통합 검증 시작"
docker compose -p bakkucca exec -T nginx nginx -s reload || true

if ! "${PROJECT_ROOT}/scripts/verify.sh"; then
  trigger_rollback
fi


# [Step 5] 원자적 심볼릭 링크 교체 (Atomic Symlink Swap)
log "[5/5] 모든 검증 통과. 심볼릭 링크 원자적 갱신"
# 1) 현재 가동 중인 버전을 previous로 보존
if [[ -L "${PROJECT_ROOT}/current" ]] && [[ -e "${PROJECT_ROOT}/current" ]]; then
  CURRENT_TARGET=$(readlink -f "${PROJECT_ROOT}/current")
  ln -sfn "$CURRENT_TARGET" "${PROJECT_ROOT}/previous_tmp"
  mv -Tf "${PROJECT_ROOT}/previous_tmp" "${PROJECT_ROOT}/previous"
fi

# 신규 버전을 current로 원자적 전환
ln -sfn "$RELEASE_DIR" "${PROJECT_ROOT}/current_tmp"
mv -Tf "${PROJECT_ROOT}/current_tmp" "${PROJECT_ROOT}/current"


# [Step 6] 구버전(N-2 이하) 리소스 인라인 정리 (Fail-safe)
log "[6/6] 구버전(N-2 이하) 이미지 및 릴리즈 아티팩트 정리"

clean_old_releases() {
  local current_dir previous_dir
  current_dir=$(readlink -f "${PROJECT_ROOT}/current" 2>/dev/null || echo "")
  previous_dir=$(readlink -f "${PROJECT_ROOT}/previous" 2>/dev/null || echo "")

  # 보존해야 할 활성 이미지 목록 수집 (current + previous)
  local preserve_images=()
  for active_dir in "$current_dir" "$previous_dir"; do
    if [[ -n "$active_dir" && -f "${active_dir}/.env" ]]; then
      while IFS= read -r line; do
        if [[ "$line" =~ _IMAGE=(.+) ]]; then
          preserve_images+=("${BASH_REMATCH[1]}")
        fi
      done < <(grep -E '_(IMAGE)=' "${active_dir}/.env" || true)
    fi
  done

  # releases/ 디렉터리 순회: current도 아니고 previous도 아닌 폴더(N-2 이하) 탐색
  for rel in "${PROJECT_ROOT}/releases"/*; do
    if [[ -d "$rel" && "$rel" != "$current_dir" && "$rel" != "$previous_dir" ]]; then
      local old_ver
      old_ver=$(basename "$rel")
      log "오래된 릴리즈 감지: ${old_ver} -> 리소스 회수 시작"

      # N-2 릴리즈의 .env에서 이미지 추출 후, 보존 목록에 없는 이미지만 개별 삭제
      if [[ -f "${rel}/.env" ]]; then
        while IFS= read -r line; do
          if [[ "$line" =~ _IMAGE=(.+) ]]; then
            local target_img="${BASH_REMATCH[1]}"
            # current나 previous에서 여전히 쓰이는 이미지(예: 변경 없던 AI 이미지)는 건너뜀
            if [[ ! " ${preserve_images[*]} " =~ " ${target_img} " ]]; then
              log "미사용 구버전 이미지 삭제: ${target_img}"
              docker rmi "$target_img" 2>/dev/null || true
            fi
          fi
        done < <(grep -E '_(IMAGE)=' "${rel}/.env" || true)
      fi

      # 릴리즈 디렉터리 자체 삭제 (파일시스템 용량 회수)
      rm -rf "$rel"
      log "오래된 릴리즈 폴더 삭제 완료: ${old_ver}"
    fi
  done

  # 빌드/풀 도중 생긴 태그 없는 Dangling 레이어 정리
  docker image prune -f >/dev/null 2>&1 || true
}

# 정리가 실패하더라도 이미 완료된 배포 성공(exit 0)에 영향을 주지 않도록 보호
clean_old_releases || log "[WARN] 구버전 리소스 정리 중 경고 발생 (배포 상태 영향 없음)"

log "[SUCCESS] 배포 및 구버전 정리 완료: ${TARGET_VERSION} (Active Version 확정)"
exit 0