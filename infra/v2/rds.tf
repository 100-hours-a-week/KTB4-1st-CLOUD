data "aws_vpc" "v1" {
  id = var.v1_vpc_id

  lifecycle {
    postcondition {
      condition     = self.cidr_block == var.v1_vpc_cidr
      error_message = "v1_vpc_cidr must match v1_vpc_id."
    }
  }
}

data "aws_subnet" "rds" {
  for_each = toset(var.rds_subnet_ids)
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == aws_vpc.prod.id
      error_message = "Every RDS subnet must belong to the v2 VPC."
    }
  }
}

data "aws_route_table" "v1_ec2" {
  subnet_id = var.v1_ec2_subnet_id
}

resource "aws_vpc_peering_connection" "v1_to_v2" {
  vpc_id        = aws_vpc.prod.id
  peer_vpc_id   = var.v1_vpc_id
  auto_accept   = true
  peer_region   = "ap-northeast-2"
  peer_owner_id = data.aws_caller_identity.current.account_id

  tags = {
    Name = "bakkucca-v1-to-v2-rds"
  }
}

resource "aws_route" "v2_to_v1" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.v1_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2.id
}

resource "aws_route" "v1_to_v2" {
  route_table_id            = data.aws_route_table.v1_ec2.id
  destination_cidr_block    = aws_vpc.prod.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.v1_to_v2.id
}

resource "aws_security_group" "rds_mysql" {
  name        = "bakkucca-v2-rds-mysql-sg"
  description = "Private MySQL access from the v1 EC2 VPC"
  vpc_id      = aws_vpc.prod.id

  ingress {
    description = "MySQL from the v1 EC2 VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.v1_vpc_cidr]
  }

  egress {
    description = "RDS managed network egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "v1_ec2_from_rds" {
  security_group_id = var.v1_ec2_security_group_id
  cidr_ipv4         = aws_vpc.prod.cidr_block
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
  description       = "RDS VPC MySQL replication access to the v1 EC2 proxy"
}

resource "aws_db_subnet_group" "mysql" {
  name        = "bakkucca-v2-mysql"
  description = "Private subnets for the Bakkucca v2 RDS MySQL instance"
  subnet_ids  = var.rds_subnet_ids
}

resource "aws_db_parameter_group" "mysql_84" {
  name        = "bakkucca-v2-mysql84"
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
  identifier = "bakkucca-v2-mysql"

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
  final_snapshot_identifier = "bakkucca-v2-mysql-final"
  apply_immediately         = var.rds_apply_immediately

  lifecycle {
    prevent_destroy = true
  }
}
