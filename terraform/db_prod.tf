# RDS always lives in the private subnets, regardless of use_nat_gateway. It
# needs no outbound internet at all, so there is nothing to trade off here.
resource "aws_db_subnet_group" "production" {
  name       = "${local.name_prefix}-rds-subnets"
  subnet_ids = aws_subnet.private[*].id

  description = "Private subnets for the production RDS instance"

  tags = {
    Name = "${local.name_prefix}-rds-subnets"
  }
}

# ---------------------------------------------------------------------------
# LAB-ONLY SETTINGS
#
# The four settings below are chosen so `terraform destroy` leaves nothing
# billable behind. Every one of them is wrong for a real production database:
#
#   skip_final_snapshot     = true   -> must be false. A final snapshot is the
#                                       only copy left after a deletion.
#   deletion_protection     = false  -> must be true. It is the guard against a
#                                       destroy that was meant for another
#                                       workspace.
#   backup_retention_period = 1      -> must be 7 or more, matched to the
#                                       recovery window the business accepts.
#   multi_az                = false  -> must be true where an AZ outage is not
#                                       an acceptable outage.
#
# apply_immediately = true is also a lab choice: in production it forces changes
# outside the maintenance window.
# ---------------------------------------------------------------------------

resource "aws_db_instance" "production" {
  identifier = "${local.name_prefix}-production"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.rds_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_schema_name
  username = var.db_master_username
  password = random_password.rds_master.result

  db_subnet_group_name   = aws_db_subnet_group.production.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                   = false
  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true
  skip_final_snapshot        = true
  deletion_protection        = false

  tags = {
    Name      = "${local.name_prefix}-production"
    FlywayEnv = "production"
  }
}

# The Flyway user cannot be created here.
#
# On EC2 the bootstrap script runs on the database host itself. RDS has no host
# to run anything on, and Terraform has no network path into the private subnet,
# so the least-privilege user is created once by hand from the runner over SSM.
# The exact SQL and the exact mysql command are in README.md, section
# "Post-apply: complete the setup".
#
# Deliberately not automated with a MySQL provider: that would require Terraform
# itself to hold a route into the VPC and the master password in a second place.
