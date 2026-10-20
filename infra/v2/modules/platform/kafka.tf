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

# 기존 운영 kafka 인스턴스의 주소만 이전
moved {
  from = aws_instance.kafka
  to   = aws_instance.kafka[0]
}

# Kafka 전용 EC2 생성과 SSH 공개키 등록
resource "aws_instance" "kafka" {
  count = var.environment == "dev" ? 0 : 1

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
    }, jsondecode(var.environment == "staging" ? jsonencode({
      packages = ["java-17-amazon-corretto-headless"]
      runcmd = [
        # 운영과 같은 Kafka 버전과 systemd 실행 설정으로 스테이징 구성
        ["bash", "-ec", <<-EOT
        curl -fsSL --retry 5 https://archive.apache.org/dist/kafka/4.3.1/kafka_2.13-4.3.1.tgz -o /tmp/kafka.tgz
        curl -fsSL --retry 5 https://archive.apache.org/dist/kafka/4.3.1/kafka_2.13-4.3.1.tgz.sha512 -o /tmp/kafka.sha512
        expected=$(cut -d: -f2 /tmp/kafka.sha512 | tr -d '[:space:]')
        echo "$expected  /tmp/kafka.tgz" | sha512sum -c -
        id kafka >/dev/null 2>&1 || useradd --system --home-dir /opt/kafka --shell /sbin/nologin kafka
        install -d /opt/kafka /etc/kafka /var/lib/kafka/data
        tar -xzf /tmp/kafka.tgz --strip-components=1 -C /opt/kafka
        token=$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
        private_ip=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/local-ipv4)
        cat > /etc/kafka/server.properties <<CONFIG
        process.roles=broker,controller
        node.id=1
        controller.quorum.bootstrap.servers=127.0.0.1:9093
        listeners=PLAINTEXT://$private_ip:9092,CONTROLLER://127.0.0.1:9093
        advertised.listeners=PLAINTEXT://$private_ip:9092
        listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
        controller.listener.names=CONTROLLER
        inter.broker.listener.name=PLAINTEXT
        log.dirs=/var/lib/kafka/data
        num.partitions=1
        offsets.topic.replication.factor=1
        transaction.state.log.replication.factor=1
        transaction.state.log.min.isr=1
        CONFIG
        chown -R kafka:kafka /opt/kafka /var/lib/kafka
        if [ ! -f /var/lib/kafka/data/meta.properties ]; then
          cluster_id=$(sudo -u kafka /opt/kafka/bin/kafka-storage.sh random-uuid)
          sudo -u kafka /opt/kafka/bin/kafka-storage.sh format --standalone -t "$cluster_id" -c /etc/kafka/server.properties
        fi
        cat > /etc/systemd/system/kafka.service <<UNIT
        [Unit]
        Description=Apache Kafka (KRaft)
        After=network-online.target
        Wants=network-online.target
        [Service]
        Type=simple
        User=kafka
        Group=kafka
        Environment="KAFKA_HEAP_OPTS=-Xms512m -Xmx512m"
        ExecStart=/opt/kafka/bin/kafka-server-start.sh /etc/kafka/server.properties
        Restart=on-failure
        RestartSec=5
        LimitNOFILE=100000
        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable --now kafka
        for attempt in $(seq 1 60); do
          sudo -u kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$private_ip:9092" --list && break
          [ "$attempt" -lt 60 ] || exit 1
          sleep 5
        done
        for topic in item-view-events item-view-events-retry item-view-events-dlt search-history-events search-history-events-retry-1000 search-history-events-retry-2000 search-history-events-retry-4000 search-history-events-dlt; do
          sudo -u kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$private_ip:9092" --create --if-not-exists --topic "$topic" --partitions 1 --replication-factor 1 --config min.insync.replicas=1
        done
        EOT
        ],
      ]
  }) : "{}")))}"

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
