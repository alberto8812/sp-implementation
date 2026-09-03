# One password per environment. If the dev password leaks, the blast radius
# stops at dev. Reusing one password across three environments would make the
# environment boundary in GitHub decorative.
resource "random_password" "flyway" {
  for_each = toset(local.environments)

  length  = 24
  special = true

  # The generated value travels through a shell heredoc, an ini file, a MySQL
  # IDENTIFIED BY literal and a JDBC URL. override_special keeps it to
  # characters that need no escaping in any of them.
  override_special = local.password_special
}

resource "random_password" "rds_master" {
  length           = 24
  special          = true
  override_special = local.password_special
}

# ---------------------------------------------------------------------------
# Parameter Store
#
# Passwords never appear in Terraform outputs. Everything an operator needs is
# readable back with a single get-parameters-by-path call, which is also the
# only place the MySQL bootstrap script reads its password from.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_password" {
  for_each = toset(local.environments)

  name        = "${local.ssm_prefix}/${each.key}/db_password"
  description = "Flyway user password for the ${each.key} environment"
  type        = "SecureString"
  value       = random_password.flyway[each.key].result

  tags = {
    Name = "${local.name_prefix}-${each.key}-db-password"
  }
}

resource "aws_ssm_parameter" "rds_master_password" {
  name        = "${local.ssm_prefix}/production/rds_master_password"
  description = "RDS master password. Used once to create the least-privilege Flyway user; not used by the pipeline."
  type        = "SecureString"
  value       = random_password.rds_master.result

  tags = {
    Name = "${local.name_prefix}-rds-master-password"
  }
}

resource "aws_ssm_parameter" "db_user" {
  for_each = toset(local.environments)

  name        = "${local.ssm_prefix}/${each.key}/db_user"
  description = "Flyway database user for the ${each.key} environment"
  type        = "String"
  value       = var.flyway_db_user
}

resource "aws_ssm_parameter" "db_name" {
  for_each = toset(local.environments)

  name        = "${local.ssm_prefix}/${each.key}/db_name"
  description = "Schema Flyway owns in the ${each.key} environment"
  type        = "String"
  value       = var.db_schema_name
}

resource "aws_ssm_parameter" "db_port" {
  for_each = toset(local.environments)

  name        = "${local.ssm_prefix}/${each.key}/db_port"
  description = "MySQL port for the ${each.key} environment"
  type        = "String"
  value       = "3306"
}

# Host parameters are written after the instances exist. The MySQL bootstrap
# does not read them, so there is no ordering problem: the password parameter is
# created first, the instance boots and reads it, then its address is recorded
# here.
resource "aws_ssm_parameter" "db_host_dev" {
  name        = "${local.ssm_prefix}/dev/db_host"
  description = "Private IP of the dev MySQL EC2 instance"
  type        = "String"
  value       = aws_instance.mysql_dev.private_ip
}

resource "aws_ssm_parameter" "db_host_test" {
  name        = "${local.ssm_prefix}/test/db_host"
  description = "Private IP of the test MySQL EC2 instance"
  type        = "String"
  value       = aws_instance.mysql_test.private_ip
}

resource "aws_ssm_parameter" "db_host_production" {
  name        = "${local.ssm_prefix}/production/db_host"
  description = "Endpoint address of the production RDS instance"
  type        = "String"
  value       = aws_db_instance.production.address
}
