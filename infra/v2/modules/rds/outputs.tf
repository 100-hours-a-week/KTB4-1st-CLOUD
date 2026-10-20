output "endpoint" { value = aws_db_instance.mysql.address }
output "port" { value = aws_db_instance.mysql.port }
output "security_group_id" { value = aws_security_group.rds_mysql.id }
output "master_secret_arn" {
  value     = aws_db_instance.mysql.master_user_secret[0].secret_arn
  sensitive = true
}

# DB 생성 결과를 BE의 기존 SSM 주입 경로에 전달
output "jdbc_url" {
  value = "jdbc:mysql://${aws_db_instance.mysql.address}:${aws_db_instance.mysql.port}/${var.rds_database_name}"
}
