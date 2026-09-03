# Same rationale as the dev host: Ubuntu 22.04 so the engine is MySQL 8.0, not
# MariaDB. See the comment on data.aws_ami.ubuntu_jammy in db_dev.tf.
#
# Placed in the second subnet so the two hosts land in different AZs. That is
# not for availability in a lab; it makes an AZ-specific networking mistake
# visible instead of hidden.
resource "aws_instance" "mysql_test" {
  ami           = data.aws_ami.ubuntu_jammy.id
  instance_type = var.mysql_ec2_instance_type

  subnet_id                   = local.workload_subnet_ids[1]
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
    environment        = "test"
    db_schema_name     = var.db_schema_name
    flyway_db_user     = var.flyway_db_user
    password_parameter = aws_ssm_parameter.db_password["test"].name
    aws_region         = var.aws_region
  })

  user_data_replace_on_change = true

  tags = {
    Name      = "${local.name_prefix}-mysql-test"
    FlywayEnv = "test"
    Role      = "mysql-server"
  }
}
