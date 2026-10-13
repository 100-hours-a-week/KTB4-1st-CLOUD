# target과 runner EC2를 생성한다.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_subnet" "az_a" {
  availability_zone = "ap-northeast-2a"
  default_for_az    = true
}

# 테스트 인스턴스 간 통신과 SSH를 허용한다.
resource "aws_security_group" "loadtest" {
  name   = "bakkucca-loadtest"
  vpc_id = data.aws_subnet.az_a.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {

  ami = "ami-03166d7b34377cc5f"

  instances = {
    target = "t4g.small"
    runner = "t4g.large"
  }

  user_data = <<-EOT
    #!/bin/bash
    set -eux
    dnf install -y docker openssl python3 tar gzip
    systemctl enable --now docker
    usermod -aG docker ec2-user
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  EOT
}

resource "aws_instance" "loadtest" {
  for_each = local.instances

  ami                    = local.ami
  instance_type          = each.value
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.loadtest.id]
  key_name               = "bakkucca-v1"
  user_data              = local.user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = {
    Name = "bakkucca-loadtest-${each.key}"
  }
}

output "ip" {
  value = { for name, instance in aws_instance.loadtest : name => { public = instance.public_ip, private = instance.private_ip } }
}
