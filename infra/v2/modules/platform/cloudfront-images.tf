# SSM에서 이미지 서명 검증용 공개키 조회
data "aws_ssm_parameter" "image_signing_public_key" {
  name            = "/${local.name_prefix}/be/CLOUDFRONT_PUBLIC_KEY_PEM"
  with_decryption = false
}

# 개발과 스테이징의 업로드 데이터를 별도 버킷에 저장
resource "aws_s3_bucket" "uploads" {
  count  = var.existing_uploads_bucket_name == null ? 1 : 0
  bucket = "${local.name_prefix}-uploads-${data.aws_caller_identity.current.account_id}"
}

# 신규 업로드 버킷의 퍼블릭 접근 차단
resource "aws_s3_bucket_public_access_block" "uploads" {
  count                   = var.existing_uploads_bucket_name == null ? 1 : 0
  bucket                  = aws_s3_bucket.uploads[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 해당 환경의 브라우저에서 presigned URL 업로드 허용
resource "aws_s3_bucket_cors_configuration" "uploads" {
  count  = var.existing_uploads_bucket_name == null ? 1 : 0
  bucket = aws_s3_bucket.uploads[0].id
  cors_rule {
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = [for domain in local.web_domains : "https://${domain}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 해당 환경의 업로드 버킷을 이미지 원본으로 조회
data "aws_s3_bucket" "uploads" {
  bucket = var.existing_uploads_bucket_name != null ? var.existing_uploads_bucket_name : aws_s3_bucket.uploads[0].id
}

# BE가 발급한 이미지 URL의 서명을 검증할 공개키 등록
resource "aws_cloudfront_public_key" "images" {
  name_prefix = "${local.name_prefix}-images-"
  encoded_key = nonsensitive(data.aws_ssm_parameter.image_signing_public_key.value)

  lifecycle {
    precondition {
      condition = can(regex(
        "^-----BEGIN PUBLIC KEY-----[[:space:]]+[A-Za-z0-9+/=[:space:]]+-----END PUBLIC KEY-----[[:space:]]*$",
        data.aws_ssm_parameter.image_signing_public_key.value
      ))
      error_message = "CLOUDFRONT_PUBLIC_KEY_PEM에 BEGIN PUBLIC KEY 형식의 PEM 공개키를 등록해야 함"
    }
  }
}

# 이미지 경로에서 신뢰할 공개키 그룹 생성
resource "aws_cloudfront_key_group" "images" {
  name  = "${local.name_prefix}-images"
  items = [aws_cloudfront_public_key.images.id]
}

# CloudFront에서 업로드 버킷으로 보내는 요청에 서명 적용
resource "aws_cloudfront_origin_access_control" "uploads" {
  name                              = "${local.name_prefix}-uploads"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 서명 값과 사용자 쿠키를 캐시 키에서 제외해 동일 이미지 캐시 공유 (1시간)
resource "aws_cloudfront_cache_policy" "images" {
  name        = "${local.name_prefix}-images"
  min_ttl     = 0
  default_ttl = 3600
  max_ttl     = 3600
  parameters_in_cache_key_and_forwarded_to_origin {
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

# CloudFront에서 S3 업로드 이미지의 읽기만 허용
resource "aws_s3_bucket_policy" "uploads_cloudfront" {
  bucket = data.aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontImageRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${data.aws_s3_bucket.uploads.arn}/images/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.web.arn } }
    }]
  })
}
