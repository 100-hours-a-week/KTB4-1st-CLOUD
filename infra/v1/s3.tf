# 업로드 이미지 저장용 버킷
resource "aws_s3_bucket" "uploads" {
  bucket = "bakkucca-uploads"
}

# 외부 접속 차단
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 브라우저가 BE에서 받은 presigned URL로 S3에 직접 업로드(PUT)하므로 FE 도메인에 CORS 허용
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = [
      "https://${var.domain_name}",
      "https://www.${var.domain_name}",
      "http://127.0.0.1:3000", # 로컬 개발
      "http://localhost:3000", # 로컬 개발
    ]
    allowed_headers = ["*"] # BE가 presigned URL과 함께 내려주는 필수 헤더(requiredHeaders)를 그대로 보냄
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 백엔드 로컬 개발용 - 이 버킷에만 Put/Get/Delete, 계정 전체 권한(Infra-Admin) 아님
resource "aws_iam_user" "backend_dev" {
  name = "backend-dev-uploads"
}

resource "aws_iam_user_policy" "backend_dev" {
  name = "backend-dev-uploads-s3"
  user = aws_iam_user.backend_dev.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          # BE가 업로드 이미지에 pending 태그를 붙이고(PutObject 시), 읽고, 등록 시 바꾼다
          "s3:PutObjectTagging",
          "s3:GetObjectTagging",
        ]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "backend_dev" {
  user = aws_iam_user.backend_dev.name
}
