locals {
  name_prefix = var.project_name

  common_tags = {
    Project     = var.project_name
    ManagedBy   = "terraform"
    Environment = "lab"
    Lifecycle   = "disposable"
  }

  # Two AZs is the minimum an RDS DB subnet group accepts, even for a single-AZ
  # instance.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # /20 blocks out of a /16. Indices 0-1 are public, 2-3 private, which keeps the
  # numbering readable when reading the console.
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 2)]

  # Subnet placement rule for the runner and the two MySQL hosts.
  #
  # These instances need outbound internet: the runner polls GitHub over 443 and
  # downloads the Flyway CLI from Maven Central, and the MySQL hosts install
  # packages from the distribution mirrors. There are exactly two ways to give
  # them that.
  #
  #   use_nat_gateway = false (default) -> public subnet, public IP, and a
  #   Security Group with zero ingress rules. Nothing can reach them; they can
  #   still reach out. Costs nothing beyond the instances.
  #
  #   use_nat_gateway = true -> private subnet, no public IP, egress through the
  #   NAT Gateway. Cleaner, and roughly 32 USD per month.
  #
  # RDS is never affected by this flag: it always sits in the private subnets
  # with publicly_accessible = false, because it needs no internet at all.
  workload_subnet_ids = var.use_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id

  assign_public_ip = !var.use_nat_gateway

  # Every parameter this lab writes lives under this prefix, which is also what
  # the IAM policies are scoped to.
  ssm_prefix = "/${var.project_name}"

  # dev and test run MySQL on EC2; production runs on RDS. Passwords are
  # generated per environment so a leak stops at one environment.
  environments = ["dev", "test", "production"]

  # Characters that survive a MySQL client, a JDBC URL, an ini file and a shell
  # single-quoted string without escaping. Notably excluded: @ / \ " ' $ ` # ;
  password_special = "!*+,-.:=?_~"
}
