# 데이터 서버와 BE가 공유할 개발 DB 이름 조회
data "aws_ssm_parameter" "mysql_database" {
  name = "/bakkucca-v2-dev/data/MYSQL_DATABASE"
}

# 개발 MySQL과 Valkey를 실행할 ARM64 AMI 조회
data "aws_ami" "data" {
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

# 개발 BE에서만 DB와 캐시 접속 허용
resource "aws_security_group" "data" {
  name        = "bakkucca-v2-dev-data-sg"
  description = "Development MySQL and Valkey"
  vpc_id      = module.platform.vpc_id
  tags        = { Name = "bakkucca-v2-dev-data-sg" }
}
resource "aws_vpc_security_group_ingress_rule" "data_be" {
  for_each                     = toset(["3306", "6379"])
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = module.platform.security_group_ids.be
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# 개발 BE의 데이터 서버 목적지 아웃바운드 허용
resource "aws_vpc_security_group_egress_rule" "be_data" {
  for_each                     = toset(["3306", "6379"])
  security_group_id            = module.platform.security_group_ids.be
  referenced_security_group_id = aws_security_group.data.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

# 컨테이너 다운로드와 SSM 연결에 필요한 HTTPS 허용
resource "aws_vpc_security_group_egress_rule" "data_https" {
  security_group_id = aws_security_group.data.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# 데이터 EC2 관리에 사용할 IAM 역할
resource "aws_iam_role" "data" {
  name = "bakkucca-v2-dev-data"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "data_ssm" {
  role       = aws_iam_role.data.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "data" {
  name = "bakkucca-v2-dev-data"
  role = aws_iam_role.data.name
}

# 데이터 컨테이너의 일반 설정과 비밀번호 조회
resource "aws_iam_role_policy" "data_parameters" {
  name = "runtime-parameters"
  role = aws_iam_role.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.data.account_id}:parameter/bakkucca-v2-dev/data/MYSQL_DATABASE",
        "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.data.account_id}:parameter/bakkucca-v2-dev/be/DB_USERNAME",
        "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.data.account_id}:parameter/bakkucca-v2-dev/be/DB_PASSWORD",
        "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.data.account_id}:parameter/bakkucca-v2-dev/be/SPRING_DATA_REDIS_PASSWORD",
        "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.data.account_id}:parameter/bakkucca-v2-dev/data/MYSQL_ROOT_PASSWORD",
      ]
    }]
  })
}
data "aws_caller_identity" "data" {}

# 개발 BE 두 태스크가 공유할 데이터 EC2 생성
resource "aws_instance" "data" {
  ami                         = data.aws_ami.data.id
  instance_type               = "t4g.small"
  subnet_id                   = module.platform.public_subnet_ids["ap-northeast-2a"]
  vpc_security_group_ids      = [aws_security_group.data.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.data.name

  user_data_replace_on_change = true

  # 최초 부팅에서 볼륨을 준비하고 재부팅 시에도 AWS 설정으로 컨테이너 실행
  user_data = <<-BOOT
    #!/bin/bash
    set -eu
    umask 077
    dnf install -y docker python3 awscli-2
    systemctl enable --now docker
    install -d /usr/local/lib/docker/cli-plugins /opt/bakkucca-data
    curl -fsSL --retry 5 https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-aarch64 -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose

    for entry in mysql:${aws_ebs_volume.data["mysql"].id} valkey:${aws_ebs_volume.data["valkey"].id}; do
      data_name=$(echo "$entry" | cut -d: -f1)
      volume_id=$(echo "$entry" | cut -d: -f2 | tr -d '-')
      device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$volume_id"
      for attempt in $(seq 1 120); do
        [ -b "$device" ] && break
        sleep 5
      done
      [ -b "$device" ]
      if ! blkid "$device" >/dev/null 2>&1; then
        mkfs.ext4 "$device"
      fi
      uuid=$(blkid -s UUID -o value "$device")
      [ -n "$uuid" ]
      install -d "/srv/bakkucca/$data_name"
      grep -q "UUID=$uuid " /etc/fstab || echo "UUID=$uuid /srv/bakkucca/$data_name ext4 defaults,nofail 0 2" >> /etc/fstab
      mountpoint -q "/srv/bakkucca/$data_name" || mount "/srv/bakkucca/$data_name"
    done

    cat > /opt/bakkucca-data/start.py <<'PYTHON'
    import json
    import os
    import subprocess
    from pathlib import Path

    os.umask(0o077)
    def aws(*args):
        result = subprocess.check_output(["aws", "--region", "ap-northeast-2", *args], text=True)
        return json.loads(result)

    parameters = aws("ssm", "get-parameters", "--with-decryption", "--names",
        "/bakkucca-v2-dev/data/MYSQL_DATABASE", "/bakkucca-v2-dev/be/DB_USERNAME",
        "/bakkucca-v2-dev/be/DB_PASSWORD", "/bakkucca-v2-dev/be/SPRING_DATA_REDIS_PASSWORD",
        "/bakkucca-v2-dev/data/MYSQL_ROOT_PASSWORD")
    values = {p["Name"].rsplit("/", 1)[-1]: p["Value"] for p in parameters["Parameters"]}
    # Compose가 비밀번호의 달러 기호를 환경변수로 해석하지 않도록 처리
    def literal(value):
        return str(value).replace("$", "$$")

    logging = {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}
    compose = {"name": "bakkucca-dev-data", "services": {
        "mysql": {
            "image": "mysql:8.4", "restart": "unless-stopped", "mem_limit": "1g",
            "ports": ["3306:3306"], "stop_grace_period": "1m",
            "environment": {
                "MYSQL_ROOT_PASSWORD": literal(values["MYSQL_ROOT_PASSWORD"]),
                "MYSQL_DATABASE": literal(values["MYSQL_DATABASE"]),
                "MYSQL_USER": literal(values["DB_USERNAME"]),
                "MYSQL_PASSWORD": literal(values["DB_PASSWORD"]), "TZ": "Asia/Seoul"},
            "command": ["--innodb-buffer-pool-size=256M", "--performance-schema=OFF", "--max-connections=40", "--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci"],
            "volumes": ["/srv/bakkucca/mysql:/var/lib/mysql"], "logging": logging,
            "healthcheck": {"test": ["CMD-SHELL", 'MYSQL_PWD="$$MYSQL_PASSWORD" mysql --protocol=tcp -h127.0.0.1 -u"$$MYSQL_USER" -D"$$MYSQL_DATABASE" -e "SELECT 1"' ], "interval": "10s", "timeout": "5s", "retries": 12, "start_period": "30s"}},
        "valkey": {
            "image": "valkey/valkey:8", "restart": "unless-stopped", "mem_limit": "500m",
            "ports": ["6379:6379"],
            "environment": {"REDISCLI_AUTH": literal(values["SPRING_DATA_REDIS_PASSWORD"])},
            "command": ["valkey-server", "--requirepass", literal(values["SPRING_DATA_REDIS_PASSWORD"]), "--appendonly", "yes", "--maxmemory", "300mb", "--maxmemory-policy", "noeviction"],
            "volumes": ["/srv/bakkucca/valkey:/data"], "logging": logging,
            "healthcheck": {"test": ["CMD", "valkey-cli", "ping"], "interval": "10s", "timeout": "5s", "retries": 12}}
    }}
    path = Path("/opt/bakkucca-data/compose.json")
    path.write_text(json.dumps(compose))
    path.chmod(0o600)
    subprocess.run(["docker", "compose", "-f", str(path), "up", "-d", "--wait", "--wait-timeout", "180"], check=True)
    PYTHON

    cat > /etc/systemd/system/bakkucca-data.service <<'UNIT'
    [Unit]
    Description=Bakkucca development data containers
    Requires=docker.service
    After=docker.service network-online.target
    Wants=network-online.target
    RequiresMountsFor=/srv/bakkucca/mysql /srv/bakkucca/valkey
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    WorkingDirectory=/opt/bakkucca-data
    ExecStart=/usr/bin/python3 /opt/bakkucca-data/start.py
    Restart=on-failure
    RestartSec=30
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now bakkucca-data.service
  BOOT

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    delete_on_termination = true
  }
  tags = { Name = "bakkucca-v2-dev-data" }

  lifecycle {
    ignore_changes = [ami]
  }
  depends_on = [
    aws_iam_role_policy_attachment.data_ssm,
    aws_iam_role_policy.data_parameters,
    aws_vpc_security_group_egress_rule.data_https,
  ]
}

# MySQL과 Valkey 데이터를 인스턴스 루트 디스크와 분리
resource "aws_ebs_volume" "data" {
  for_each          = toset(["mysql", "valkey"])
  availability_zone = "ap-northeast-2a"
  type              = "gp3"
  size              = 10
  encrypted         = true
  tags              = { Name = "bakkucca-v2-dev-${each.key}" }
}
resource "aws_volume_attachment" "data" {
  for_each    = { mysql = "/dev/sdf", valkey = "/dev/sdg" }
  device_name = each.value
  volume_id   = aws_ebs_volume.data[each.key].id
  instance_id = aws_instance.data.id
}

# 개발 데이터 컨테이너 설정에 필요한 접속 정보 출력
output "data" {
  value = {
    instance_id = aws_instance.data.id
    private_ip  = aws_instance.data.private_ip
    mysql_port  = 3306
    valkey_port = 6379
    volume_ids  = { for name, volume in aws_ebs_volume.data : name => volume.id }
  }
}
