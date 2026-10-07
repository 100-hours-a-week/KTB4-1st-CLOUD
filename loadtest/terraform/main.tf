# 부하 테스트용 임시 EC2 2대. state는 로컬에 두고, 측정이 끝나면 terraform destroy로 지워야함
#   target: 운영 EC2(bakkucca-v1)와 같은 인스턴스 타입·AMI·AZ·디스크
#   runner: k6, Prometheus, Loki, Grafana 실행을 위한 인스턴스
# 사용법: terraform apply / terraform destroy
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

# 보안그룹
# 같은 그룹 내에서는 모든 포트와 프로토콜 ingress, egress 허용
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
  # 운영 EC2 AMI으로 고정
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
  for_each = local.instances # 위에서 정의한 두 인스턴스 각각에 대해서 같은 설정을 적용

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
