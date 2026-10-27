# 기존 DB 네트워크를 유지하며 platform 모듈에서 재사용
moved {
  from = module.migration_network.aws_vpc.this
  to   = module.platform.aws_vpc.prod
}

moved {
  from = module.migration_network.aws_subnet.private["ap-northeast-2a"]
  to   = module.platform.aws_subnet.private["ap-northeast-2a"]
}

moved {
  from = module.migration_network.aws_subnet.private["ap-northeast-2c"]
  to   = module.platform.aws_subnet.private["ap-northeast-2c"]
}

moved {
  from = module.migration_network.aws_route_table.private[0]
  to   = module.platform.aws_route_table.private[0]
}

moved {
  from = module.migration_network.aws_route_table_association.private["ap-northeast-2a"]
  to   = module.platform.aws_route_table_association.private["ap-northeast-2a"]
}

moved {
  from = module.migration_network.aws_route_table_association.private["ap-northeast-2c"]
  to   = module.platform.aws_route_table_association.private["ap-northeast-2c"]
}
