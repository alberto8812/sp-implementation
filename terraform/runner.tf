# Resolving the AMI through the public SSM parameter keeps this module free of
# hardcoded, region-specific AMI IDs that go stale within weeks.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "runner" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.runner_instance_type

  subnet_id                   = local.workload_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.runner.id]
  associate_public_ip_address = local.assign_public_ip
  iam_instance_profile        = aws_iam_instance_profile.runner.name

  # No key_name anywhere in this module. Access is Session Manager only, so
  # there is no SSH key to lose and no port 22 to leave open.

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only. With IMDSv1 reachable, a single SSRF in anything running on
    # this host hands out the instance role's credentials.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/runner.sh.tftpl", {
    github_owner   = var.github_owner
    github_repo    = var.github_repo
    github_pat     = var.github_pat
    runner_labels  = var.runner_labels
    runner_version = var.runner_version
    runner_name    = "${local.name_prefix}-runner"
  })

  # Editing the bootstrap script should rebuild the runner. Without this the
  # script changes in state but the running instance keeps its original
  # registration, and the two drift apart silently.
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name_prefix}-gh-runner"
    Role = "github-actions-runner"
  }
}
