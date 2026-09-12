data "aws_ssm_parameter" "ubuntu_24" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "control_plane" {
  ami                         = data.aws_ssm_parameter.ubuntu_24.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.control_plane]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 20
    volume_type            = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane"
    Role = "control-plane"
  })
}

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = data.aws_ssm_parameter.ubuntu_24.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[count.index % length(aws_subnet.public)].id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.data_plane]
  associate_public_ip_address = true

  root_block_device {
    volume_size            = 20
    volume_type            = "gp3"
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-worker-${count.index + 1}"
    Role = "worker"
  })
}