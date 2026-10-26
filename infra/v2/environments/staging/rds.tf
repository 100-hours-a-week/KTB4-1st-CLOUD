variable "rds_database_name" {
  type    = string
  default = "market"
}

variable "rds_master_username" {
  type    = string
  default = "admin"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "rds_max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "rds_backup_retention_days" {
  type    = number
  default = 7
}

variable "rds_backup_window" {
  type    = string
  default = "18:00-18:30"
}

variable "rds_maintenance_window" {
  type    = string
  default = "sun:19:00-sun:19:30"
}

variable "rds_deletion_protection" {
  type    = bool
  default = true
}

variable "rds_apply_immediately" {
  type    = bool
  default = false
}

module "rds" {
  source                       = "../../modules/rds"
  environment                  = "staging"
  vpc_id                       = module.migration_network.vpc_id
  rds_subnet_ids               = values(module.migration_network.private_subnet_ids)
  backend_security_group_id    = null
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
