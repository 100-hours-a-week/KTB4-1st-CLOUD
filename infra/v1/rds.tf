locals {
  rds_subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_subnet_group" "mysql" {
  name        = "bakkucca-v1-mysql"
  description = "Private subnets for the Bakkucca v1 RDS MySQL instance"
  subnet_ids  = local.rds_subnet_ids

  tags = {
    Name = "bakkucca-v1-mysql"
  }

  lifecycle {
    precondition {
      condition     = length(local.rds_subnet_ids) >= 2
      error_message = "RDS requires at least two subnets in different Availability Zones."
    }
  }
}

resource "aws_db_parameter_group" "mysql_84" {
  name        = "bakkucca-v1-mysql84"
  family      = "mysql8.4"
  description = "Bakkucca v1 MySQL 8.4 migration parameters"

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

  tags = {
    Name = "bakkucca-v1-mysql84"
  }
}

resource "aws_security_group" "rds_mysql" {
  name        = "bakkucca-v1-rds-mysql-sg"
  description = "Private MySQL access from the Bakkucca v1 EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from the v1 EC2 security group"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.v1.id]
  }

  egress {
    description = "RDS managed network egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bakkucca-v1-rds-mysql-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_rds_mysql" {
  security_group_id            = aws_security_group.v1.id
  referenced_security_group_id = aws_security_group.rds_mysql.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "RDS MySQL replication access to the EC2 MySQL proxy"
}

resource "aws_db_instance" "mysql" {
  identifier = "bakkucca-v1-mysql"

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
  final_snapshot_identifier = "bakkucca-v1-mysql-final"

  apply_immediately = var.rds_apply_immediately

  tags = {
    Name = "bakkucca-v1-mysql"
  }

  lifecycle {
    prevent_destroy = true
  }
}
