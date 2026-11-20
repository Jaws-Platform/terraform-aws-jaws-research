provider "aws" {
  region = "us-east-1"

  # The modules take no tag map. Every resource inherits these, and each
  # module adds `Component` and `Name`. `Project` matters beyond cost reports:
  # a launch role built with the jaws-ci family finds the launch template, the
  # security group and the subnets by it, so it is the same as `project` below.
  default_tags {
    tags = {
      Project     = "chess-bot"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# Task instances reach out (packages, the code under test, SSM, S3) and are
# never reached: public subnets, and a security group without ingress.
module "network" {
  source = "git::https://github.com/jwallace145/terraform-aws-jaws-network.git//modules/vpc?ref=v0.1.0"

  name       = "acme-chess-bot"
  cidr_block = "10.40.0.0/16"
}

# One task profile, `cpu`, with every default: a launch template for
# c8a.xlarge instances on the latest Amazon Linux 2023 image, with stable
# Rust, that shut themselves down six hours after boot. No dataset.
#
# This creates no instance. A launcher starts one per task from the template.
module "research" {
  source = "../../"

  name_root = "acme"
  project   = "chess-bot"
  vpc_id    = module.network.vpc_id
}

# The module names the results bucket and grants each task instance its own
# prefix of it; the caller creates it. Results are copied back by the
# launcher, so a week is plenty.
module "task_results" {
  source = "git::https://github.com/jwallace145/terraform-aws-jaws-foundation.git//modules/private-bucket?ref=v0.1.0"

  name                           = module.research.results_bucket_name
  current_object_expiration_days = 7
}

output "launch_template_name" {
  description = "The launch template a launcher starts task instances from."
  value       = module.research.launch_template_names["cpu"]
}

output "subnet_ids" {
  description = "The public subnets a launcher picks from, one per launch."
  value       = module.network.public_subnet_ids
}

output "log_group_name" {
  description = "Where task output is streamed."
  value       = module.research.log_group_name
}

output "results_uri" {
  description = "Where each task instance writes its results, under its own prefix."
  value       = module.research.results_uri
}
