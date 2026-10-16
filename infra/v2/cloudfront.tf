# cloudfront.tf: 정적 파일은 S3에서 캐시해 제공하고, 나머지 요청은 ALB로 전달하도록 구성
# 정적 파일 버킷 이름에 사용할 AWS 계정 ID 조회
data "aws_caller_identity" "current" {}

# FE 빌드 정적 파일을 저장할 버킷 생성
resource "aws_s3_bucket" "fe_static" {
  bucket = "${local.name_prefix}-fe-static-${data.aws_caller_identity.current.account_id}"
}

# 정적 파일 버킷의 퍼블릭 접근 차단
resource "aws_s3_bucket_public_access_block" "fe_static" {
  bucket                  = aws_s3_bucket.fe_static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront에서 S3로 보내는 요청에 서명 적용
resource "aws_cloudfront_origin_access_control" "fe_static" {
  name                              = "${local.name_prefix}-fe-static"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront용 HTTPS 인증서를 버지니아 리전에 발급
resource "aws_acm_certificate" "cloudfront" {
  provider                  = aws.us_east_1
  domain_name               = local.domain_name
  subject_alternative_names = ["www.${local.domain_name}"]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# 같은 도메인의 ACM 검증 CNAME은 리전 간 공유
resource "aws_acm_certificate_validation" "cloudfront" {
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [
    for domain in [local.domain_name, "www.${local.domain_name}"] : aws_route53_record.alb_certificate[domain].fqdn
  ]
}

# FE 요청 경로와 정적 파일 종류별 캐시 정책 연결
locals {
  static_cache_ttls = {
    next_static = 31536000
    public      = 300
  }
  # Nextjs의 호출 경로와 동일하게 설정 (nextjs에서 /public/을 떼고 요청합니다)
  static_paths = {
    next_static = { path = "/_next/static/*", policy = "next_static" }
    icons       = { path = "/icons/*", policy = "public" }
    figma       = { path = "/figma/*", policy = "public" }
    kakao_login = { path = "/kakao_login_large_wide.png", policy = "public" }
  }
}

# 정적 파일 캐시에서 쿠키와 쿼리 문자열 제외 (캐시 중복 저장을 방지하기 위함)
resource "aws_cloudfront_cache_policy" "static" {
  for_each = local.static_cache_ttls

  name        = "${local.name_prefix}-${each.key}"
  min_ttl     = 0
  default_ttl = each.value
  max_ttl     = each.value
  parameters_in_cache_key_and_forwarded_to_origin {
    # 브라우저가 지원하는 압축 형식에 맞춰 파일을 캐싱하고 전달
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# 정적 요청은 S3로 나머지 요청은 ALB로 전달
resource "aws_cloudfront_distribution" "web" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [local.domain_name, "www.${local.domain_name}"]
  comment         = "${local.name_prefix} web"

  # 원본 1. 정적 파일 경로: 캐시를 채우거나 재검증할 원본 경로 = S3
  origin {
    origin_id                = "fe-static"
    domain_name              = aws_s3_bucket.fe_static.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.fe_static.id
    s3_origin_config {
      origin_access_identity = ""
    }
  }
  # 사용자 업로드 이미지는 기존 S3 버킷에서 조회
  origin {
    origin_id                = "uploads"
    domain_name              = data.aws_s3_bucket.uploads.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads.id
    s3_origin_config {
      origin_access_identity = ""
    }
  }
  # 원본 2. 그 외 요청은 ALB -> 캐시 없이 전달
  origin {
    origin_id   = "alb"
    domain_name = local.alb_origin_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }
  }
  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https" # 캐시 없이 전달
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # CachingDisabled / AllViewer: 인증과 BFF, WebSocket 요청 전달
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }
  # 정적 파일 경로별 S3 원본과 캐시 정책 적용
  dynamic "ordered_cache_behavior" {
    for_each = local.static_paths
    content {
      path_pattern           = ordered_cache_behavior.value.path
      target_origin_id       = "fe-static"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true
      cache_policy_id        = aws_cloudfront_cache_policy.static[ordered_cache_behavior.value.policy].id
    }
  }
  # 이미지 조회에는 BE가 발급한 유효한 CloudFront 서명 필수
  ordered_cache_behavior {
    path_pattern           = "/images/*"
    target_origin_id       = "uploads"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.images.id
    trusted_key_groups     = [aws_cloudfront_key_group.images.id]
  }
  # 인증 실패와 서버 오류 응답의 캐시 유지 방지
  dynamic "custom_error_response" {
    for_each = [400, 403, 404, 405, 414, 500, 501, 502, 503, 504]
    content {
      error_code            = custom_error_response.value
      error_caching_min_ttl = 0 # 오류 응답의 강제 캐시 시간 제거 (서비스 복구 시 실시간으로 반영하기 위함)
    }
  }
  # 국내 전용 설정
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["KR"]
    }
  }
  # 브라우저-cloudfront 간 https 설정
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  depends_on = [aws_route53_record.alb_origin, aws_lb_listener.https]
}

# 해당 CloudFront 배포에만 정적 파일 읽기 허용 (S3 미공개)
resource "aws_s3_bucket_policy" "fe_static" {
  bucket = aws_s3_bucket.fe_static.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.fe_static.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.web.arn } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.fe_static]
}
