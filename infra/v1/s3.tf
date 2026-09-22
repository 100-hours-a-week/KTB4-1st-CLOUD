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
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "backend_dev" {
  user = aws_iam_user.backend_dev.name
}
