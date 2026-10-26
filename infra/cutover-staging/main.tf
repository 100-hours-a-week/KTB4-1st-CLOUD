terraform {
  required_version = ">= 1.16, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.68" }
  }
  backend "s3" {
    bucket       = "bakkucca-terraform-state"
    key          = "cutover/staging-v1/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { Project = "bakkucca", Environment = "cutover-staging", ManagedBy = "terraform" }
  }
}

data "aws_key_pair" "ssh" {
  for_each           = toset(["bakkucca-v1", "bakkucca-v1-janna"])
  key_name           = each.key
  include_public_key = true
}
resource "aws_instance" "rehearsal" {
  for_each                    = { source = { type = "t4g.small", disk = 30, sg = "sg-070a9c527a6292fb2" } }
  ami                         = "ami-0171e38cc88437aa1"
  instance_type               = each.value.type
  subnet_id                   = "subnet-02514cb3bc238b48d"
  vpc_security_group_ids      = [each.value.sg, "sg-0f5c610d9f44f8e2b"]
  associate_public_ip_address = true
  key_name                    = "bakkucca-v1"
  iam_instance_profile        = aws_iam_instance_profile.runtime.name
  user_data_replace_on_change = true
  user_data                   = <<-BOOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker openssl python3 tar gzip
    systemctl enable --now docker amazon-ssm-agent
    usermod -aG docker ec2-user
    install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
    cat >> /home/ec2-user/.ssh/authorized_keys <<'SSH_KEYS'
    ${join("\n", [for key in data.aws_key_pair.ssh : replace(trimspace(key.public_key), "\\n", "")])}
    SSH_KEYS
    chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
    chmod 600 /home/ec2-user/.ssh/authorized_keys
    install -d /usr/local/lib/docker/cli-plugins /opt/app/shared
    curl -fsSL --retry 5 https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-aarch64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
    BOOT

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.disk
    encrypted             = true
    delete_on_termination = false
  }
  tags = { Name = "bakkucca-cutover-staging-v1" }
  # cloud-init 변경은 신규 인스턴스에 사용하고 기존 서버에는 개별 반영한다.
  lifecycle { ignore_changes = [ami, user_data] }
}

output "instances" { value = { for name, i in aws_instance.rehearsal : name => { id = i.id, private_ip = i.private_ip, public_ip = i.public_ip } } }

data "aws_ssm_parameter" "uploads" {
  name = "/bakkucca-v2-staging/be/AWS_S3_BUCKET"
}
resource "aws_iam_role" "runtime" {
  name               = "bakkucca-cutover-staging-v1"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }] })
}
resource "aws_iam_instance_profile" "runtime" {
  name = "bakkucca-cutover-staging-v1"
  role = aws_iam_role.runtime.name
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runtime.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "runtime" {
  name = "staging-runtime"
  role = aws_iam_role.runtime.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ssm:GetParameters", "ssm:GetParameter", "ssm:GetParametersByPath"], Resource = "arn:aws:ssm:ap-northeast-2:502147243433:parameter/bakkucca-v2-staging/*" },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = "arn:aws:secretsmanager:ap-northeast-2:502147243433:secret:rds!db-a929cb54-e8bb-4f0e-89ad-45fb50e0f42f-gaUXV7" },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${nonsensitive(data.aws_ssm_parameter.uploads.value)}/*" }
  ] })
}
