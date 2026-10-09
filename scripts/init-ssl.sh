#!/bin/bash
set -e

DOMAIN="bakkucca.com"
EMAIL="jy04169@gmail.com"
STAGING=0 # 테스트 시 1, 실제 발급 시 0

if docker compose run --rm certbot certificates 2>/dev/null | grep -q "Certificate Name: $DOMAIN"; then
    echo ">>> [SSL] 이미 유효한 $DOMAIN 인증서가 존재합니다. 발급을 건너뜁니다."
    exit 0
fi

STAGING_FLAG=""
if [ "$STAGING" != "0" ]; then
  STAGING_FLAG="--staging"
fi

echo ">>> [SSL] Certbot Standalone 모드로 초기 공인 인증서 발급..."
# Nginx 구동 전이므로 80 포트를 Certbot 컨테이너에 직접 매핑하여 검증
docker compose run --rm -p 80:80 certbot certonly \
  --standalone \
  -d "$DOMAIN" \
  -d "www.$DOMAIN" \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  $STAGING_FLAG

echo ">>> [SSL] $DOMAIN 공인 인증서 최초 발급 완료"