#!/usr/bin/env bash
# GHCR(Docker Registry API)에서 이미지가 실제로 존재하는지 확인하고, Release Bundle에 기록할 메타데이터를 JSON으로 출력한다.
#
# 사용법: ghcr-inspect.sh <이미지 URI> <태그 또는 sha256 digest>
#   예) ghcr-inspect.sh ghcr.io/100-hours-a-week/ktb4-1st-be v1.0.1
# 출력: {"digest": "sha256:...", "git_commit_sha": "...", "built_at": "..."}
#   - git_commit_sha, built_at은 CI(docker/metadata-action)가 붙인 OCI 라벨(revision, created)에서 읽는다.
# 인증: GHCR_TOKEN(+GHCR_USER) 환경변수가 있으면 사용하고, 없으면 익명으로 요청한다(공개 이미지만 조회 가능).
set -euo pipefail

image="$1"
ref="$2"
repo="${image#ghcr.io/}"

auth=()
if [ -n "${GHCR_TOKEN:-}" ]; then
  auth=(-u "${GHCR_USER:-token}:${GHCR_TOKEN}")
fi

if ! token=$(curl -fsSL ${auth[@]+"${auth[@]}"} "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" | jq -er '.token'); then
  echo "::error::GHCR 인증 실패: ${image} 읽기 권한이 없습니다. GHCR_TOKEN(read:packages) 또는 패키지의 Actions 접근 권한을 확인하세요." >&2
  exit 1
fi

accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch_manifest() {
  curl -sSL -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
    "https://ghcr.io/v2/${repo}/manifests/$1"
}

code=$(fetch_manifest "$ref")
if [ "$code" != "200" ]; then
  echo "::error::GHCR에서 이미지를 찾을 수 없습니다: ${image}:${ref} (HTTP ${code})" >&2
  exit 1
fi

# 태그가 가리키는 최상위 digest. 멀티 아키텍처 이미지면 index의 digest이며, 배포 시 이 값으로 pull한다.
digest=$(grep -i '^docker-content-digest:' "$tmp/headers" | tail -1 | awk '{print $2}' | tr -d '\r')
content_type=$(grep -i '^content-type:' "$tmp/headers" | tail -1 | awk '{print $2}' | tr -d '\r')

# 멀티 아키텍처 index면 운영 서버(Graviton)에 맞는 linux/arm64 manifest를 골라 라벨을 읽는다.
case "$content_type" in
  *index*|*manifest.list*)
    arm64=$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "arm64")][0].digest // empty' "$tmp/body")
    if [ -z "$arm64" ]; then
      echo "::error::linux/arm64 이미지가 없습니다: ${image}:${ref}" >&2
      exit 1
    fi
    fetch_manifest "$arm64" > /dev/null
    ;;
esac

config_digest=$(jq -r '.config.digest' "$tmp/body")
curl -fsSL -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/blobs/${config_digest}" > "$tmp/config"

jq -n \
  --arg digest "$digest" \
  --slurpfile config "$tmp/config" \
  '{
    digest: $digest,
    git_commit_sha: ($config[0].config.Labels["org.opencontainers.image.revision"] // ""),
    built_at: ($config[0].config.Labels["org.opencontainers.image.created"] // "")
  }'
