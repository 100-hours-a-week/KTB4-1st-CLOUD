variable "v1_vpc_cidr" {
  description = "CIDR of the existing v1 VPC that hosts the legacy EC2 MySQL"
  type        = string
  default     = "172.31.0.0/16"
}

variable "v1_vpc_id" {
  description = "Existing v1 default VPC ID"
  type        = string
}

variable "v1_ec2_subnet_id" {
  description = "Existing v1 EC2 subnet ID used to add the peering route"
  type        = string
}

variable "v1_ec2_security_group_id" {
  description = "Existing v1 EC2 security group ID; only its 3306 ingress rule is managed here"
  type        = string
}

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

variable "rds_subnet_ids" {
  description = "At least two v2 private subnet IDs in different AZs"
  type        = list(string)

  validation {
    condition     = length(var.rds_subnet_ids) >= 2
    error_message = "rds_subnet_ids must contain at least two subnets."
  }
}
