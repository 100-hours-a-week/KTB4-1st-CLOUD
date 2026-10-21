terraform {
  required_version = ">= 1.16, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.68" }
  }
  backend "s3" {
    bucket       = "bakkucca-terraform-state"
    key          = "migration/staging-v1/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = { Project = "bakkucca", Environment = "migration-staging", ManagedBy = "terraform" }
  }
}

variable "access_cidrs" {
  type    = set(string)
  default = ["172.31.0.0/16"]
}

data "aws_subnet" "source" {
  availability_zone = "ap-northeast-2a"
  default_for_az    = true
}
data "aws_vpc" "source" { id = data.aws_subnet.source.vpc_id }
data "aws_key_pair" "ssh" {
  for_each           = toset(["bakkucca-v1", "bakkucca-v1-janna"])
  key_name           = each.key
  include_public_key = true
}
data "aws_route_table" "source" {
  vpc_id = data.aws_subnet.source.vpc_id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}
data "aws_ami" "arm64" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "source" {
  name        = "bakkucca-migration-staging-v1"
  description = "Isolated v1 rehearsal instance in the default VPC"
  vpc_id      = data.aws_subnet.source.vpc_id
}
resource "aws_vpc_security_group_ingress_rule" "source" {
  for_each = {
    for pair in setproduct(var.access_cidrs, toset(["80", "443"])) :
    "${pair[0]}:${pair[1]}" => { cidr = pair[0], port = tonumber(pair[1]) }
  }
  security_group_id = aws_security_group.source.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
}
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = { source = aws_security_group.source.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}
resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each          = { source = aws_security_group.source.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "instance" {
  for_each = toset(["source"])
  name     = "bakkucca-migration-staging-${each.key}"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = aws_iam_role.instance
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "instance" {
  for_each = aws_iam_role.instance
  name     = "bakkucca-migration-staging-${each.key}"
  role     = each.value.name
}

data "aws_caller_identity" "current" {}
resource "aws_iam_role_policy" "runtime" {
  name = "staging-runtime"
  role = aws_iam_role.instance["source"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters"]
      Resource = [for name in [
        "ai/ANTHROPIC_API_KEY", "be/KAKAO_CLIENT_ID", "be/KAKAO_CLIENT_SECRET",
        "be/PROMETHEUS_AUTH_USERNAME", "be/PROMETHEUS_AUTH_PASSWORD", "fe/KAKAO_REST_API_KEY"
      ] : "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/bakkucca-v2-staging/${name}"]
    }]
  })
}

# 시험 업로드는 운영 버킷과 분리한다.
resource "aws_s3_bucket" "uploads" {
  bucket_prefix = "bakkucca-migration-staging-"
}
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = ["https://staging.bakkucca.com", "https://${aws_instance.rehearsal["source"].public_ip}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}
resource "aws_iam_role_policy" "uploads" {
  role = aws_iam_role.instance["source"].id
  name = "rehearsal-uploads"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.uploads.arn}/*"
    }]
  })
}

resource "aws_instance" "rehearsal" {
  for_each = {
    source = { type = "t4g.small", disk = 30, sg = aws_security_group.source.id }
  }
  ami                         = data.aws_ami.arm64.id
  instance_type               = each.value.type
  subnet_id                   = data.aws_subnet.source.id
  vpc_security_group_ids      = [each.value.sg]
  associate_public_ip_address = true
  key_name                    = "bakkucca-v1"
  iam_instance_profile        = aws_iam_instance_profile.instance[each.key].name
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
    install -d /usr/local/lib/docker/cli-plugins /opt/bakkucca-migration
    curl -fsSL --retry 5 https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-aarch64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
    dnf install -y socat mariadb105
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
  tags = { Name = "bakkucca-migration-staging-${each.key}" }
  # cloud-init 변경은 신규 인스턴스에 사용하고 기존 서버에는 개별 반영한다.
  lifecycle { ignore_changes = [ami, user_data] }
}

output "instances" {
  value = { for name, instance in aws_instance.rehearsal : name => {
    id = instance.id, private_ip = instance.private_ip, public_ip = instance.public_ip
  } }
}
output "v1_network" {
  value = {
    vpc_id            = data.aws_vpc.source.id
    cidr_block        = data.aws_vpc.source.cidr_block
    route_table_id    = data.aws_route_table.source.id
    security_group_id = aws_security_group.source.id
  }
}
output "uploads_bucket" { value = aws_s3_bucket.uploads.id }
