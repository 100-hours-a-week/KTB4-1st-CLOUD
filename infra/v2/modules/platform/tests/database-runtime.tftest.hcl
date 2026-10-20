mock_provider "aws" {
  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:ghcr-test"
    }
  }
}
mock_provider "aws" {
  alias = "us_east_1"
}

override_data {
  target = data.aws_ssm_parameter.image_signing_public_key
  values = {
    value = "-----BEGIN PUBLIC KEY-----\nVEVTVA==\n-----END PUBLIC KEY-----"
  }
}

# 인증서의 계산 속성은 테스트에서 고정해 DNS 생성과 무관하게 런타임 연결 검증
override_resource {
  target          = aws_acm_certificate.alb
  override_during = plan
  values = {
    arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    domain_validation_options = [
      {
        domain_name           = "example.com"
        resource_record_name  = "_validation.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.example.invalid"
      },
      {
        domain_name           = "www.example.com"
        resource_record_name  = "_validation.www.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.example.invalid"
      },
      {
        domain_name           = "origin.example.com"
        resource_record_name  = "_validation.origin.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.example.invalid"
      },
    ]
  }
}

override_resource {
  target          = aws_acm_certificate.cloudfront
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
  }
}

variables {
  environment = "prod"
  domain_name = "example.com"
  vpc_cidr    = "10.20.0.0/16"
  public_subnets = {
    ap-northeast-2a = "10.20.0.0/24"
    ap-northeast-2c = "10.20.1.0/24"
  }
  redis_parameters = {}
}

run "rds_password_only_accessible_to_backend" {
  command = plan
  variables {
    database_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-test"
  }

  assert {
    condition = one([
      for secret in jsondecode(output.be_task_definition_template).containerDefinitions[0].secrets : secret.valueFrom
      if secret.name == "DB_PASSWORD"
    ]) == "${var.database_secret_arn}:password::"
    error_message = "The backend must inject only the password JSON key from its RDS-managed secret."
  }
  assert {
    condition     = !contains(keys(local.runtime_parameter_names.be), "DB_PASSWORD")
    error_message = "RDS-backed environments must not require an SSM DB_PASSWORD parameter."
  }
  assert {
    condition = (
      contains(jsondecode(aws_iam_role_policy.execution_registry["be"].policy).Statement[0].Resource, var.database_secret_arn) &&
      !contains(jsondecode(aws_iam_role_policy.execution_registry["fe"].policy).Statement[0].Resource, var.database_secret_arn) &&
      !contains(jsondecode(aws_iam_role_policy.execution_registry["ai"].policy).Statement[0].Resource, var.database_secret_arn)
    )
    error_message = "Only the backend execution role may read the RDS-managed secret."
  }
}

run "existing_ssm_password_path_is_preserved" {
  command = plan

  assert {
    condition     = local.runtime_parameter_names.be.DB_PASSWORD == "/bakkucca-v2-prod/be/DB_PASSWORD"
    error_message = "Without an RDS secret ARN, the existing SSM password path must be preserved."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.execution_registry["be"].policy).Statement[0].Resource) == toset([data.aws_secretsmanager_secret.ghcr.arn])
    error_message = "Without an RDS secret ARN, Secrets Manager access must remain limited to GHCR."
  }
}
