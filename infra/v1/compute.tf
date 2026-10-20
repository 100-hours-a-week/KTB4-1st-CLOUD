resource "aws_key_pair" "v1" {
  key_name   = "bakkucca-v1"
  public_key = file(pathexpand(var.ssh_key_path))
}

resource "aws_instance" "v1" {
  ami                    = var.ec2_ami_id
  instance_type          = "t4g.small"
  subnet_id              = var.ec2_subnet_id
  vpc_security_group_ids = [aws_security_group.v1.id]
  key_name               = aws_key_pair.v1.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.data_volume_size_gb
    delete_on_termination = false
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
