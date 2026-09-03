# Security Groups are declared with no inline ingress/egress blocks and every
# rule as a separate aws_vpc_security_group_*_rule resource. That is the AWS
# provider 5.x model: each rule gets its own ID, so a plan shows which single
# rule changed instead of a whole-group diff.

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

resource "aws_security_group" "runner" {
  name        = "${local.name_prefix}-sg-flyway-runner"
  description = "GitHub Actions self-hosted runner for Flyway migrations. No inbound access; SSM Session Manager only."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-sg-flyway-runner"
  }
}

# Deliberately no aws_vpc_security_group_ingress_rule for this group.
#
# The runner dials out to GitHub and polls for work; GitHub never connects in.
# SSM Session Manager also works purely outbound, which is why there is no key
# pair and no port 22 anywhere in this module.

resource "aws_vpc_security_group_egress_rule" "runner_https" {
  security_group_id = aws_security_group.runner.id
  description       = "GitHub API and runner polling, distribution package mirrors, Maven Central for the pinned Flyway CLI"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "runner_mysql" {
  security_group_id = aws_security_group.runner.id
  description       = "MySQL to the three lab databases, restricted to the VPC so a misconfigured host name cannot reach a database on the internet"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}

# ---------------------------------------------------------------------------
# MySQL on EC2 (dev and test)
# ---------------------------------------------------------------------------

resource "aws_security_group" "mysql_ec2" {
  name        = "${local.name_prefix}-sg-flyway-mysql-ec2"
  description = "MySQL 8.0 on EC2 for the dev and test environments. Reachable only from the runner Security Group."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-sg-flyway-mysql-ec2"
  }
}

# Granting by Security Group reference rather than by CIDR means the rule keeps
# working when the runner is replaced and its private IP changes.
resource "aws_vpc_security_group_ingress_rule" "mysql_ec2_from_runner" {
  security_group_id = aws_security_group.mysql_ec2.id
  description       = "MySQL from the Flyway runner only"

  referenced_security_group_id = aws_security_group.runner.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "mysql_ec2_https" {
  security_group_id = aws_security_group.mysql_ec2.id
  description       = "apt package installs, snap for the SSM agent, and SSM endpoint traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

# The Ubuntu bootstrap talks to the archive mirrors over plain HTTP as well as
# HTTPS, so port 80 has to be open outbound or apt-get hangs.
resource "aws_vpc_security_group_egress_rule" "mysql_ec2_http" {
  security_group_id = aws_security_group.mysql_ec2.id
  description       = "Ubuntu archive mirrors over HTTP during first boot"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# ---------------------------------------------------------------------------
# RDS (production)
# ---------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-sg-flyway-rds"
  description = "Production RDS MySQL. Reachable only from the runner Security Group; no egress."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-sg-flyway-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_runner" {
  security_group_id = aws_security_group.rds.id
  description       = "MySQL from the Flyway runner only"

  referenced_security_group_id = aws_security_group.runner.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# No egress rule is declared for the RDS group, and that is intentional rather
# than an omission. Terraform removes the allow-all egress rule AWS creates by
# default, and a managed RDS instance initiates no outbound connections of its
# own. Leaving the group with zero egress rules is the tightest correct answer.
