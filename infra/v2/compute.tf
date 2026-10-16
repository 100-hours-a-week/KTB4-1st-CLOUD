# Kafka EC2에 사용할 최신 ARM64 AMI 조회
data "aws_ami" "kafka_al2023_arm64" {
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

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Kafka SSH 접속에 사용할 기존 공개키 조회
data "aws_key_pair" "kafka_ssh" {
  for_each = toset(["bakkucca-v1", "bakkucca-v1-janna"])

  key_name           = each.key
  include_public_key = true
}

# Kafka 전용 EC2 생성과 SSH 공개키 등록
resource "aws_instance" "kafka" {
  ami                         = data.aws_ami.kafka_al2023_arm64.id
  instance_type               = "t4g.small"
  subnet_id                   = aws_subnet.public["ap-northeast-2a"].id
  vpc_security_group_ids      = [aws_security_group.kafka.id]
  associate_public_ip_address = true

  user_data = "#cloud-config\n${yamlencode({
    ssh_pwauth   = false
    disable_root = true
    ssh_authorized_keys = [
      trimspace(data.aws_key_pair.kafka_ssh["bakkucca-v1"].public_key),
      trimspace(data.aws_key_pair.kafka_ssh["bakkucca-v1-janna"].public_key),
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGntCupNVtCchM374J7tFhBo0nLM0ckh+Cyp24zZJ8oi martin",
    ]
  })}"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = false
  }

  tags = {
    Name = "${local.name_prefix}-kafka"
  }

  # AMI 검색 결과 변경에 따른 Kafka EC2 자동 교체 방지
  lifecycle {
    ignore_changes = [ami]
  }
}
