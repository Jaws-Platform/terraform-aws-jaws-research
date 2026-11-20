locals {
  # Modules take no tag map. Every resource inherits these through the
  # provider's default_tags, and each module adds `Component` (and `Name`).
  tags = {
    Organization = "acme"
    Project      = "chess-bot"
    Environment  = "prod"
    Repository   = "acme/chess-bot"
    ManagedBy    = "terraform"
    Owner        = "platform-team"
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}

module "vpc" {
  source = "git::https://github.com/jwallace145/terraform-aws-jaws-network.git//modules/vpc?ref=v0.1.0"

  name       = "acme-chess-bot"
  cidr_block = "10.40.0.0/16"
}

# The caller owns the results bucket the task instances write to.
module "task_results" {
  source = "git::https://github.com/jwallace145/terraform-aws-jaws-foundation.git//modules/private-bucket?ref=v0.1.0"

  name                           = "acme-chess-bot-tasks"
  current_object_expiration_days = 7
}

module "tasks" {
  source = "../../"

  name_root          = "acme"
  project            = "chess-bot"
  vpc_id             = module.vpc.vpc_id
  rust_toolchain     = "1.91.0"
  max_lifetime_hours = 6
}

output "launch_template_name" {
  value = module.tasks.launch_template_name
}
