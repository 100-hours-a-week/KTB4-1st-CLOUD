# prod와 같은 RDS MySQL 8.4 사양을 개발 환경에서 독립적으로 운영
module "rds" {
  source                       = "../../modules/rds"
  environment                  = "dev"
  vpc_id                       = module.platform.vpc_id
  rds_subnet_ids               = values(module.platform.private_subnet_ids)
  backend_security_group_id    = module.platform.backend_security_group_id
  rds_database_name            = var.rds_database_name
  rds_master_username          = var.rds_master_username
  rds_instance_class           = var.rds_instance_class
  rds_allocated_storage_gb     = var.rds_allocated_storage_gb
  rds_max_allocated_storage_gb = var.rds_max_allocated_storage_gb
  rds_backup_retention_days    = var.rds_backup_retention_days
  rds_backup_window            = var.rds_backup_window
  rds_maintenance_window       = var.rds_maintenance_window
  rds_deletion_protection      = var.rds_deletion_protection
  rds_apply_immediately        = var.rds_apply_immediately
}
