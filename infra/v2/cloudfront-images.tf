# 이미지 서명 검증에 사용할 공개키 입력
variable "image_signing_public_key_pem" {
  type        = string
  nullable    = false
  description = "BE 서명용 RSA 2048 개인키에 대응하는 공개키 PEM"

  validation {
    condition = can(regex(
      "^-----BEGIN PUBLIC KEY-----[[:space:]]+[A-Za-z0-9+/=[:space:]]+-----END PUBLIC KEY-----[[:space:]]*$",
      var.image_signing_public_key_pem
    ))
    error_message = "BEGIN PUBLIC KEY 형식의 PEM 공개키를 입력해야 함"
  }
}

# 기존 사용자 업로드 버킷을 조회해 이미지 원본으로 사용
data "aws_s3_bucket" "uploads" {
  bucket = "bakkucca-uploads"
}

# BE가 발급한 이미지 URL의 서명을 검증할 공개키 등록
resource "aws_cloudfront_public_key" "images" {
  name_prefix = "${local.name_prefix}-images-"
  encoded_key = var.image_signing_public_key_pem
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
