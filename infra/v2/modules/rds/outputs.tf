output "endpoint" { value = aws_db_instance.mysql.address }
output "port" { value = aws_db_instance.mysql.port }
output "security_group_id" { value = aws_security_group.rds_mysql.id }
output "master_secret_arn" {
  value     = aws_db_instance.mysql.master_user_secret[0].secret_arn
  sensitive = true
}
