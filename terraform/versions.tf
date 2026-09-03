terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State backend.
  #
  # Local state is deliberate here: this module is a disposable lab that one
  # person applies and destroys from one machine, and a remote backend would add
  # two more resources that outlive `terraform destroy`.
  #
  # For anything shared by a team, uncomment the block below. Without remote
  # state and locking, two concurrent applies silently overwrite each other and
  # the generated database passwords in state are stored unencrypted on disk.
  #
  # backend "s3" {
  #   bucket         = "<your-tf-state-bucket>"
  #   key            = "flyway-demo/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "<your-tf-lock-table>"
  #   encrypt        = true
  # }
}
