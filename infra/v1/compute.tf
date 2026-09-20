# t4g small EC2
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_key_pair" "v1" {
  key_name   = "bakkucca-v1"
  public_key = file(pathexpand(var.ssh_key_path))
}

resource "aws_instance" "v1" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = "t4g.small"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.v1.id]
  key_name               = aws_key_pair.v1.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.data_volume_size_gb
  }

  tags = {
    Name = "bakkucca-v1"
  }
}

resource "aws_eip" "v1" {
  instance = aws_instance.v1.id
  domain   = "vpc"

  tags = {
    Name = "bakkucca-v1"
  }
}
