provider "aws" {
  region = "us-east-1"

  # The modules take no tag map. Every resource inherits these, and each
  # module adds `Component` and `Name`. `Project` matters beyond cost reports:
  # a launch role built with the jaws-ci family finds the launch templates,
  # the security group and the subnets by it, so it is the same as `project`
  # below.
  default_tags {
    tags = {
      Project     = "chess-bot"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

variable "dataset_reader_role_arns" {
  description = "Existing IAM roles that may read the positions, for example the role of a Databricks storage credential. S3 rejects a bucket policy that names a role that does not exist, so the default is none."
  type        = list(string)
  default     = []
}

# The GPU image is resolved from a pinned name, so that every training run
# gets the same NVIDIA driver and CUDA. Deprecated images are included so
# that the pin keeps resolving. Change the name deliberately to upgrade.
data "aws_ami" "deep_learning" {
  owners             = ["amazon"]
  include_deprecated = true
  most_recent        = false

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023) 20261027"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

module "network" {
  source = "git::https://github.com/jaws-platform/terraform-aws-jaws-network.git//modules/vpc?ref=v0.1.0"

  name       = "acme-chess-bot"
  cidr_block = "10.40.0.0/16"
}

# Two task profiles and two datasets. Self-play on CPU instances adds
# positions; training on GPU instances reads them and adds nets.
#
# This creates no instance. A launcher starts one per task from a profile's
# launch template.
module "research" {
  source = "../../"

  name_root          = "acme"
  project            = "chess-bot"
  vpc_id             = module.network.vpc_id
  log_retention_days = 30

  profiles = {
    # Self-play and benchmarks: many cores, a pinned Rust toolchain.
    cpu = {
      default_instance_type = "c8a.16xlarge"
      rust_toolchain        = "1.91.0"
    }

    # Training: an NVIDIA GPU, the image that ships its driver, a larger disk
    # for the data, and no Rust.
    gpu = {
      gpu                   = true
      ami_id                = data.aws_ami.deep_learning.id
      default_instance_type = "g6.xlarge"
      root_volume_gb        = 200
      rust                  = false
    }
  }

  datasets = {
    # cpu instances add positions anywhere under data/, and can never read
    # or delete them. gpu instances read the self-play positions. Scratch
    # files under data/tmp/ expire; nothing else ever does.
    positions = {
      prefix           = "data/"
      writer_profiles  = ["cpu"]
      profile_grants   = { gpu = { read = ["selfplay/"] } }
      reader_role_arns = var.dataset_reader_role_arns
      expire_prefixes  = { "tmp/" = 30 }
    }

    # gpu instances add nets and can never overwrite one. Versioned, so that
    # anything an administrator overwrites or deletes can be recovered for 90
    # days.
    nets = {
      prefix                 = "data/"
      profile_grants         = { gpu = { write_once = ["nets/"] } }
      versioning             = true
      expire_noncurrent_days = 90
    }
  }
}

# The module names the results bucket and grants each task instance its own
# prefix of it; the caller creates it.
module "task_results" {
  source = "git::https://github.com/jaws-platform/terraform-aws-jaws-foundation.git//modules/private-bucket?ref=v0.1.0"

  name                           = module.research.results_bucket_name
  current_object_expiration_days = 14
}

output "launch_template_names" {
  description = "The launch template of each profile, which a launcher starts task instances from."
  value       = module.research.launch_template_names
}

output "subnet_ids" {
  description = "The public subnets a launcher picks from, one per launch."
  value       = module.network.public_subnet_ids
}

output "dataset_uris" {
  description = "Where each dataset's data lives."
  value       = module.research.dataset_uris
}

output "results_uri" {
  description = "Where each task instance writes its results, under its own prefix."
  value       = module.research.results_uri
}
