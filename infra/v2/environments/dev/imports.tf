# 기존 SSM 파라미터가 AWS에는 있지만 dev Terraform state에는 없는 경우 인계
import {
  to = module.platform.aws_ssm_parameter.service_endpoint["be/DB_USERNAME"]
  id = "/bakkucca-v2-dev/be/DB_USERNAME"
}
