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
