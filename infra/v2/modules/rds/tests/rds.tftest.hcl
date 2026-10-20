mock_provider "aws" {
  mock_resource "aws_db_instance" {
    override_during = plan
    defaults = {
      address = "rds.example.invalid"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:test"
        kms_key_id    = "test-key"
        secret_status = "active"
      }]
    }
  }
}

variables {
  environment               = "prod"
  vpc_id                    = "vpc-test"
  backend_security_group_id = "sg-backend-test"
  rds_subnet_ids            = ["subnet-test-a", "subnet-test-c"]
}

run "prod_private_database" {
  command = plan

  assert {
    condition = (
      aws_db_instance.mysql.identifier == "bakkucca-v2-prod-mysql" &&
      !aws_db_instance.mysql.publicly_accessible &&
      aws_db_instance.mysql.multi_az &&
      aws_db_instance.mysql.storage_encrypted &&
      aws_db_instance.mysql.manage_master_user_password
    )
    error_message = "prod RDS must use an environment-specific name, private access, Multi-AZ, encryption, and a managed master password."
  }
}

run "staging_database_is_separate" {
  command = plan
  variables {
    environment = "staging"
  }

  assert {
    condition = (
      aws_db_instance.mysql.identifier == "bakkucca-v2-staging-mysql" &&
      aws_db_subnet_group.mysql.name == "bakkucca-v2-staging-mysql" &&
      aws_db_parameter_group.mysql_84.name == "bakkucca-v2-staging-mysql84" &&
      aws_security_group.rds_mysql.name == "bakkucca-v2-staging-rds-mysql-sg"
    )
    error_message = "staging database resources must not reuse prod resource names."
  }
}

run "reject_single_subnet" {
  command = plan
  variables {
    rds_subnet_ids = ["subnet-test-a"]
  }
  expect_failures = [var.rds_subnet_ids]
}

run "jdbc_url_uses_application_database" {
  command = plan
  variables {
    rds_database_name = "application_test"
  }
  assert {
    condition     = output.jdbc_url == "jdbc:mysql://rds.example.invalid:3306/application_test"
    error_message = "The JDBC URL must use the generated RDS endpoint, port, and selected application database."
  }
}
