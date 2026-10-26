output "vpc_id" {
  value = module.migration_network.vpc_id
}

output "private_subnet_ids" {
  value = module.migration_network.private_subnet_ids
}

output "rds_mysql_endpoint" {
  value = module.rds.endpoint
}

output "rds_mysql_port" {
  value = module.rds.port
}

output "rds_mysql_security_group_id" {
  value = module.rds.security_group_id
}

output "rds_mysql_master_secret_arn" {
  value     = module.rds.master_secret_arn
  sensitive = true
}
