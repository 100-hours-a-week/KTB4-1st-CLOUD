# 실행 후 출력할 것
output "instance_id" {
  value = aws_instance.v1.id
}

output "instance_public_ip" {
  value = aws_eip.v1.public_ip
}

output "security_group_id" {
  value = aws_security_group.v1.id
}

output "upload_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "domain_record" {
  value = aws_route53_record.v1.fqdn
}

output "backend_dev_access_key_id" {
  value = aws_iam_access_key.backend_dev.id
}

output "backend_dev_secret_access_key" {
  value     = aws_iam_access_key.backend_dev.secret
  sensitive = true
}
