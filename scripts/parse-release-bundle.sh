#!/usr/bin/env bash
#
# Release Bundle YAML 파싱 및 배포 패키지(Staging) 생성 스크립트
#
set -euo pipefail

BUNDLE_VERSION="${1:-}"

# 타임스탬프 로그 출력 함수
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }

# -----------------------------------------------------------------------------
# 1. 인자 및 필수 파일 유효성 검증
# -----------------------------------------------------------------------------
if [[ -z "$BUNDLE_VERSION" ]]; then
  log_err "Bundle 버전이 지정되지 않았습니다. (사용법: $0 <bundle_version>)"
  exit 1
fi

YAML_FILE="releases/${BUNDLE_VERSION}.yaml"
COMPOSE_TEMPLATE="docker-compose.yml"

if [[ ! -f "$YAML_FILE" ]]; then
  log_err "Release Manifest 파일이 존재하지 않습니다: $YAML_FILE"
  exit 1
fi

if [[ ! -f "$COMPOSE_TEMPLATE" ]]; then
  log_err "Compose 템플릿 파일이 존재하지 않습니다: $COMPOSE_TEMPLATE"
  exit 1
fi

log "==> [1/3] Release Manifest 검증 및 파싱: $YAML_FILE"

# -----------------------------------------------------------------------------
# 2. 이미지 파싱 함수 (주의: stdout은 변수 할당에 쓰이므로 로그 출력 금지)
# -----------------------------------------------------------------------------
parse_image() {
  local service_key="$1"
  local uri digest tag

  uri=$(yq eval ".services.${service_key}.image_uri // \"\"" "$YAML_FILE")
  digest=$(yq eval ".services.${service_key}.image_digest // \"\"" "$YAML_FILE")
  tag=$(yq eval ".services.${service_key}.image_tag // \"\"" "$YAML_FILE")

  # 이미지 URI 기본 검증
  if [[ -z "$uri" || "$uri" == "null" ]]; then
    log_err "${service_key}의 image_uri를 찾을 수 없습니다."
    return 1
  fi

  # digest 우선 매핑, 없을 경우 tag로 fallback
  if [[ -n "$digest" && "$digest" != "null" ]]; then
    echo "${uri}@${digest}"
  elif [[ -n "$tag" && "$tag" != "null" ]]; then
    echo "${uri}:${tag}"
  else
    log_err "${service_key}의 image_digest 및 image_tag가 모두 누락되었습니다."
    return 1
  fi
}

BE_IMAGE=$(parse_image "backend")
AI_IMAGE=$(parse_image "ai")
FE_IMAGE=$(parse_image "frontend")

log "  - Backend  : $BE_IMAGE"
log "  - AI       : $AI_IMAGE"
log "  - Frontend : $FE_IMAGE"

# -----------------------------------------------------------------------------
# 3. 배포 스테이징 디렉터리 패키징
# -----------------------------------------------------------------------------
log "==> [2/3] 배포 아티팩트 스테이징 (build/${BUNDLE_VERSION})"

OUTPUT_DIR="build/${BUNDLE_VERSION}"
mkdir -p "$OUTPUT_DIR"

# .env.release 생성
cat <<EOF > "${OUTPUT_DIR}/.env.release"
BUNDLE_VERSION=${BUNDLE_VERSION}
SPRINGBOOT_IMAGE=${BE_IMAGE}
FASTAPI_IMAGE=${AI_IMAGE}
NEXTJS_IMAGE=${FE_IMAGE}
EOF

# Compose 템플릿을 docker-compose.yml로 복사
cp "$COMPOSE_TEMPLATE" "${OUTPUT_DIR}/docker-compose.yml"

log "==> [3/3] 패키징 완료 검증"
log "  - ${OUTPUT_DIR}/.env.release"
log "  - ${OUTPUT_DIR}/docker-compose.yml"
log "[SUCCESS] ${BUNDLE_VERSION} 배포 패키지 준비가 완료되었습니다."