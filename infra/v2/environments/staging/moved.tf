# Preserve the RDS VPC and its private DB subnets while moving them out of the app platform module.
moved {
  from = module.platform.aws_vpc.prod
  to   = module.migration_network.aws_vpc.this
}

moved {
  from = module.platform.aws_subnet.private["ap-northeast-2a"]
  to   = module.migration_network.aws_subnet.private["ap-northeast-2a"]
}

moved {
  from = module.platform.aws_subnet.private["ap-northeast-2c"]
  to   = module.migration_network.aws_subnet.private["ap-northeast-2c"]
}

moved {
  from = module.platform.aws_route_table.private[0]
  to   = module.migration_network.aws_route_table.private[0]
}

moved {
  from = module.platform.aws_route_table_association.private["ap-northeast-2a"]
  to   = module.migration_network.aws_route_table_association.private["ap-northeast-2a"]
}

moved {
  from = module.platform.aws_route_table_association.private["ap-northeast-2c"]
  to   = module.migration_network.aws_route_table_association.private["ap-northeast-2c"]
}
