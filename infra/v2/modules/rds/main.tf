terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.68" }
  }
}
locals {
  name_prefix = "bakkucca-v2-${var.environment}"
}
resource "aws_security_group" "rds_mysql" {
  name        = "${local.name_prefix}-rds-mysql-sg"
  description = "Private MySQL access"
  vpc_id      = var.vpc_id
}
resource "aws_vpc_security_group_ingress_rule" "backend" {
  count                        = var.backend_security_group_id == null ? 0 : 1
  security_group_id            = aws_security_group.rds_mysql.id
  referenced_security_group_id = var.backend_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}
resource "aws_vpc_security_group_egress_rule" "backend" {
  count                        = var.backend_security_group_id == null ? 0 : 1
  security_group_id            = var.backend_security_group_id
  referenced_security_group_id = aws_security_group.rds_mysql.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# Keep the existing rule instances stable in prod while allowing migration-only RDS without an app SG.
moved {
  from = aws_vpc_security_group_ingress_rule.backend
  to   = aws_vpc_security_group_ingress_rule.backend[0]
}

moved {
  from = aws_vpc_security_group_egress_rule.backend
  to   = aws_vpc_security_group_egress_rule.backend[0]
}
resource "aws_db_subnet_group" "mysql" {
  name        = "${local.name_prefix}-mysql"
  description = "Private subnets for the Bakkucca v2 RDS MySQL instance"
  subnet_ids  = var.rds_subnet_ids
}

resource "aws_db_parameter_group" "mysql_84" {
  name        = "${local.name_prefix}-mysql84"
  family      = "mysql8.4"
  description = "Bakkucca v2 MySQL 8.4 migration parameters"

  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "binlog_row_image"
    value        = "FULL"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.4"
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.rds_database_name
  username = var.rds_master_username

  manage_master_user_password = true
  port                        = 3306

  multi_az               = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.rds_mysql.id]
  parameter_group_name   = aws_db_parameter_group.mysql_84.name

  backup_retention_period   = var.rds_backup_retention_days
  backup_window             = var.rds_backup_window
  maintenance_window        = var.rds_maintenance_window
  copy_tags_to_snapshot     = true
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-mysql-final"
  apply_immediately         = var.rds_apply_immediately

  lifecycle {
    prevent_destroy = true
  }
}
