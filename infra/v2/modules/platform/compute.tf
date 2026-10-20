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

  user_data = "#cloud-config\n${yamlencode(merge({
    ssh_pwauth   = false
    disable_root = true
    ssh_authorized_keys = [
      trimspace(data.aws_key_pair.kafka_ssh["bakkucca-v1"].public_key),
      trimspace(data.aws_key_pair.kafka_ssh["bakkucca-v1-janna"].public_key),
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGntCupNVtCchM374J7tFhBo0nLM0ckh+Cyp24zZJ8oi martin",
    ]
    }, jsondecode(var.environment == "dev" ? jsonencode({
      packages = ["docker"]
      runcmd = [
        ["systemctl", "enable", "--now", "docker"],
        # dev BE에 사설 주소를 알리는 단일 Kafka 브로커 실행
        ["bash", "-ec", <<-EOT
        token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
        private_ip=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4)
        docker run -d --name kafka --restart unless-stopped --network host \
          --memory 1400m --log-opt max-size=10m --log-opt max-file=3 \
          -v kafka-data:/var/lib/kafka/data \
          -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
          -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://127.0.0.1:9093 \
          -e "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://$private_ip:9092" \
          -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT \
          -e KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT \
          -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
          -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:9093 \
          -e CLUSTER_ID=4L6g3nShT-eMCtK--X86sw \
          -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
          -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
          -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
          -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
          -e KAFKA_HEAP_OPTS='-Xms256m -Xmx512m' \
          -e KAFKA_LOG_RETENTION_HOURS=24 \
          -e KAFKA_LOG_RETENTION_BYTES=536870912 \
          -e KAFKA_LOG_SEGMENT_BYTES=134217728 \
          apache/kafka:4.0.2
      EOT
        ],
      ]
  }) : "{}")))}"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.environment == "prod" ? 20 : 10
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
