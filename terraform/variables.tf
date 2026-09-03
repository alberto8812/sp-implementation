variable "aws_region" {
  description = "AWS region where the entire lab is created. Everything is regional, so changing this after apply recreates the lab."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for every resource name, tag and SSM parameter path. Keep it lowercase and hyphen-separated."
  type        = string
  default     = "flyway-demo"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must be 2-31 characters, lowercase letters, digits or hyphens, and must not start with a hyphen."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC. Must be large enough for four /20 subnets carved out with cidrsubnet()."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, for example 10.42.0.0/16."
  }
}

variable "use_nat_gateway" {
  description = "When true, the runner and both MySQL instances move to private subnets and egress through a NAT Gateway. When false they sit in public subnets with no inbound rules. The NAT Gateway costs roughly 32 USD per month, so the default is false."
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository the runner registers against."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must not be empty."
  }
}

variable "github_repo" {
  description = "GitHub repository name (without the owner) the runner registers against."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repo)) > 0
    error_message = "github_repo must not be empty."
  }
}

variable "github_pat" {
  description = "Classic GitHub personal access token with the 'repo' scope. It is used once at instance boot to exchange for a short-lived runner registration token, and is never written to the bootstrap log."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.github_pat)) > 0
    error_message = "github_pat must not be empty."
  }
}

variable "runner_labels" {
  description = "Comma-separated labels passed to config.sh. The workflows target 'vpc-interna', so changing this makes queued jobs stop matching."
  type        = string
  default     = "self-hosted,linux,vpc-interna"
}

variable "runner_version" {
  description = "Pinned GitHub Actions runner release. An unpinned runner would silently change the build environment between applies."
  type        = string
  default     = "2.321.0"
}

variable "db_schema_name" {
  description = "MySQL schema that Flyway owns. The same name is used in all three environments so a single set of migrations applies unchanged."
  type        = string
  default     = "flyway_demo"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,63}$", var.db_schema_name))
    error_message = "db_schema_name must start with a letter and contain only letters, digits and underscores."
  }
}

variable "db_master_username" {
  description = "Master user for the RDS production instance. It is not the Flyway user; Flyway gets a least-privilege account created manually after apply."
  type        = string
  default     = "flyway_admin"
}

variable "flyway_db_user" {
  description = "Least-privilege MySQL user Flyway authenticates as. Grants are scoped to db_schema_name only."
  type        = string
  default     = "flyway_app"
}

variable "mysql_ec2_instance_type" {
  description = "Instance type for the dev and test MySQL hosts. Migrations are I/O bound, not CPU bound."
  type        = string
  default     = "t3.micro"
}

variable "runner_instance_type" {
  description = "Instance type for the self-hosted GitHub Actions runner."
  type        = string
  default     = "t3.micro"
}

variable "rds_instance_class" {
  description = "Instance class for the production RDS instance. Graviton (t4g) is the cheapest class that still runs MySQL 8.0."
  type        = string
  default     = "db.t4g.micro"
}
