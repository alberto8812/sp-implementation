# Ubuntu 22.04 LTS rather than Amazon Linux 2023, and the reason matters.
#
# `apt-get install mysql-server` on Jammy installs MySQL 8.0 from the base
# archive, with no third-party repository and no version pinning. Amazon Linux
# 2023 ships MariaDB instead; dev and test would then run a different engine
# from the production RDS MySQL instance, and the whole point of the promotion
# chain is that dev and test tell you what production will do.
#
# Shared by both the dev and the test host.
data "aws_ami" "ubuntu_jammy" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "mysql_dev" {
  ami           = data.aws_ami.ubuntu_jammy.id
  instance_type = var.mysql_ec2_instance_type

  subnet_id                   = local.workload_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.mysql_ec2.id]
  associate_public_ip_address = local.assign_public_ip
  iam_instance_profile        = aws_iam_instance_profile.mysql.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/mysql.sh.tftpl", {
    environment        = "dev"
    db_schema_name     = var.db_schema_name
    flyway_db_user     = var.flyway_db_user
    password_parameter = aws_ssm_parameter.db_password["dev"].name
    aws_region         = var.aws_region
  })

  user_data_replace_on_change = true

  tags = {
    Name      = "${local.name_prefix}-mysql-dev"
    FlywayEnv = "dev"
    Role      = "mysql-server"
  }
}
