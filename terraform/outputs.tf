output "vpc_id" {
  description = "ID of the lab VPC."
  value       = aws_vpc.this.id
}

output "runner_instance_id" {
  description = "Instance ID of the self-hosted GitHub Actions runner."
  value       = aws_instance.runner.id
}

output "runner_security_group_id" {
  description = "Security Group that identifies the runner. Database ingress rules reference this group rather than an IP."
  value       = aws_security_group.runner.id
}

output "dev_db_private_ip" {
  description = "Private IP of the dev MySQL host. This is the DB_HOST value for the dev environment."
  value       = aws_instance.mysql_dev.private_ip
}

output "test_db_private_ip" {
  description = "Private IP of the test MySQL host. This is the DB_HOST value for the test environment."
  value       = aws_instance.mysql_test.private_ip
}

output "rds_endpoint" {
  description = "Endpoint address of the production RDS instance. This is the DB_HOST value for the production environment."
  value       = aws_db_instance.production.address
}

output "rds_port" {
  description = "Port the production RDS instance listens on."
  value       = aws_db_instance.production.port
}

output "ssm_session_command" {
  description = "Command that opens a shell on the runner. Session Manager is the only access path; there is no SSH key and no open port 22."
  value       = "aws ssm start-session --target ${aws_instance.runner.id} --region ${var.aws_region}"
}

# Passwords are never output. Terraform outputs land in state, in CI logs and in
# shell history; Parameter Store does not. These are the paths to read instead.
output "ssm_password_paths" {
  description = "Parameter Store paths holding each generated password. Read one with: aws ssm get-parameter --name <path> --with-decryption --query Parameter.Value --output text"
  value = {
    dev             = aws_ssm_parameter.db_password["dev"].name
    test            = aws_ssm_parameter.db_password["test"].name
    production      = aws_ssm_parameter.db_password["production"].name
    rds_master_user = aws_ssm_parameter.rds_master_password.name
  }
}

output "github_secret_commands" {
  description = "The gh commands that populate each GitHub Environment. Password values are piped from Parameter Store so they never pass through the shell as literals."
  value       = <<-EOT
    # Create the three environments first (UI: Settings -> Environments), then:

    # --- dev ---
    echo "${aws_instance.mysql_dev.private_ip}" | gh secret set DB_HOST --env dev
    echo "3306"                                  | gh secret set DB_PORT --env dev
    echo "${var.db_schema_name}"                 | gh secret set DB_NAME --env dev
    echo "${var.flyway_db_user}"                 | gh secret set DB_USER --env dev
    aws ssm get-parameter --name ${aws_ssm_parameter.db_password["dev"].name} --with-decryption --query Parameter.Value --output text --region ${var.aws_region} | gh secret set DB_PASSWORD --env dev

    # --- test ---
    echo "${aws_instance.mysql_test.private_ip}" | gh secret set DB_HOST --env test
    echo "3306"                                  | gh secret set DB_PORT --env test
    echo "${var.db_schema_name}"                 | gh secret set DB_NAME --env test
    echo "${var.flyway_db_user}"                 | gh secret set DB_USER --env test
    aws ssm get-parameter --name ${aws_ssm_parameter.db_password["test"].name} --with-decryption --query Parameter.Value --output text --region ${var.aws_region} | gh secret set DB_PASSWORD --env test

    # --- production ---
    echo "${aws_db_instance.production.address}" | gh secret set DB_HOST --env production
    echo "${aws_db_instance.production.port}"    | gh secret set DB_PORT --env production
    echo "${var.db_schema_name}"                 | gh secret set DB_NAME --env production
    echo "${var.flyway_db_user}"                 | gh secret set DB_USER --env production
    aws ssm get-parameter --name ${aws_ssm_parameter.db_password["production"].name} --with-decryption --query Parameter.Value --output text --region ${var.aws_region} | gh secret set DB_PASSWORD --env production
  EOT
}
