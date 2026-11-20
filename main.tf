# Root module: one research project's task instances and its datasets.
#
#   task profiles    a launch template and a write-only instance role each.
#                    `cpu` is the project's first profile: it creates the log
#                    group and the no-ingress security group, and every other
#                    profile shares them
#   dataset buckets  zero or more kept-forever, append-only S3 buckets, which
#                    the profiles' instances may add to or read by prefix
#
# Nothing here launches an instance: a launcher (the Jaws CLI, from a GitHub
# Actions workflow) starts one per task from a profile's launch template and
# terminates it. The VPC and the task results bucket are the caller's.
#
# It only wires the two submodules together. Each can be used on its own, and
# both keep their own input validation.

module "task_runner" {
  source = "./modules/task-runner"

  name_root          = var.name_root
  project            = var.project
  profile            = "cpu"
  vpc_id             = var.vpc_id
  log_retention_days = var.log_retention_days

  gpu                   = var.profiles["cpu"].gpu
  architecture          = var.profiles["cpu"].architecture
  ami_id                = var.profiles["cpu"].ami_id
  default_instance_type = var.profiles["cpu"].default_instance_type
  root_volume_gb        = var.profiles["cpu"].root_volume_gb
  max_lifetime_hours    = var.profiles["cpu"].max_lifetime_hours
  rust_toolchain        = var.profiles["cpu"].rust ? var.profiles["cpu"].rust_toolchain : null
}

# Every other profile: its own template and role, the project's log group and
# security group.
module "task_profile" {
  source   = "./modules/task-runner"
  for_each = { for name, profile in var.profiles : name => profile if name != "cpu" }

  name_root = var.name_root
  project   = var.project
  profile   = each.key
  shared    = module.task_runner.shared
  vpc_id    = var.vpc_id

  gpu                   = each.value.gpu
  architecture          = each.value.architecture
  ami_id                = each.value.ami_id
  default_instance_type = each.value.default_instance_type
  root_volume_gb        = each.value.root_volume_gb
  max_lifetime_hours    = each.value.max_lifetime_hours
  rust_toolchain        = each.value.rust ? each.value.rust_toolchain : null
}

locals {
  # Every profile's outputs by profile name, `cpu` included.
  profiles = merge({ cpu = module.task_runner }, module.task_profile)
}

# Access is granted to the profiles' instance roles by name, so the roles
# exist before a bucket's policies are attached to them.
module "dataset_bucket" {
  source   = "./modules/dataset-bucket"
  for_each = var.datasets

  name                   = "${var.name_root}-${var.project}-${each.key}"
  prefix                 = each.value.prefix
  transition_days        = each.value.transition_days
  versioning             = each.value.versioning
  expire_noncurrent_days = each.value.expire_noncurrent_days
  expire_prefixes        = each.value.expire_prefixes
  reader_role_arns       = each.value.reader_role_arns

  writer_role_names = [
    for profile in each.value.writer_profiles : local.profiles[profile].instance_role_name
  ]
  role_grants = {
    for profile, grant in each.value.profile_grants : local.profiles[profile].instance_role_name => grant
  }
}
