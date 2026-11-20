variable "name_root" {
  description = "Prefix of every name, in kebab-case, usually the organisation: for example `acme`. Each profile's launch template, instance role and instance profile are `<name_root>-<project>-task` (with `-<profile>` appended for every profile but `cpu`), the log group is `/<name_root>/<project>/tasks`, the results bucket the caller creates is `<name_root>-<project>-tasks`, and each dataset bucket is `<name_root>-<project>-<dataset>`."
  type        = string
}

variable "project" {
  description = "Project in kebab-case, for example `chess-bot`. Every name derives from it and `name_root`, and task instances and their volumes carry it as the `Project` tag."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the task security group. The launch templates set no subnet: the launcher passes one of this VPC's public subnets with each launch."
  type        = string
}

variable "log_retention_days" {
  description = "Days CloudWatch keeps task output in the project's log group: one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180 or 365."
  type        = number
  default     = 14
}

variable "profiles" {
  description = "Task profiles by name, for example `cpu` for benchmarks and `gpu` for training. Each gets its own launch template, instance role and instance profile, so its image, disk and permissions are its own. `cpu` is required: it is the project's first profile, and it creates the log group and the security group that every other profile shares. `gpu` makes setup wait for the NVIDIA driver, and needs an image that ships the driver and CUDA, such as the AWS Deep Learning Base GPU AMI. `architecture` is `x86_64` or `arm64`. `ami_id` pins an Amazon Linux 2023 image; null follows the latest one for the architecture. `default_instance_type` is the template's type, which a launcher can override per launch. `root_volume_gb` sizes the encrypted root volume, from 20 to 200. `max_lifetime_hours`, from 1 to 24, is how long after boot an instance shuts itself down, and so terminates. `rust_toolchain` is the rustup toolchain that setup installs, and `rust = false` installs none. Profile names are kebab-case, at most 16 characters."
  type = map(object({
    gpu                   = optional(bool, false)
    architecture          = optional(string, "x86_64")
    ami_id                = optional(string)
    default_instance_type = optional(string, "c8a.xlarge")
    root_volume_gb        = optional(number, 40)
    max_lifetime_hours    = optional(number, 6)
    rust                  = optional(bool, true)
    rust_toolchain        = optional(string, "stable")
  }))
  default  = { cpu = {} }
  nullable = false

  validation {
    condition     = contains(keys(var.profiles), "cpu")
    error_message = "profiles must include `cpu`: it is the project's first profile, which creates the log group and the security group the other profiles share. `cpu = {}` takes every default."
  }
}

variable "datasets" {
  description = "Dataset buckets by name, for example `positions`. Each is a kept-forever, append-only bucket named `<name_root>-<project>-<name>`, whose data lives under `prefix` (for example `data/`). `writer_profiles` lists the profiles whose instances may add objects anywhere under the prefix; they can never read or delete. `profile_grants` gives a profile narrower access, by sub-prefix of `prefix`: `read`, `write` (add) and `write_once` (add, and never overwrite). `reader_role_arns` are existing IAM roles that may read the prefix, such as another project's training role or the role of a Databricks storage credential. `transition_days`, `versioning`, `expire_noncurrent_days` and `expire_prefixes` are the `dataset-bucket` inputs of the same names. A bucket has `prevent_destroy`, so removing its entry fails the plan until the bucket is taken out of state. `tasks` cannot be a dataset: `<name_root>-<project>-tasks` is the task results bucket."
  type = map(object({
    prefix          = string
    writer_profiles = optional(list(string), [])
    profile_grants = optional(map(object({
      read       = optional(list(string), [])
      write      = optional(list(string), [])
      write_once = optional(list(string), [])
    })), {})
    reader_role_arns       = optional(list(string), [])
    transition_days        = optional(number, 0)
    versioning             = optional(bool, false)
    expire_noncurrent_days = optional(number)
    expire_prefixes        = optional(map(number), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for name in keys(var.datasets) :
      can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", name)) && length("${var.name_root}-${var.project}-${name}") <= 63
    ])
    error_message = "datasets keys must be kebab-case (lowercase letters, digits and single hyphens), and `<name_root>-<project>-<name>` must fit S3's 63-character bucket name limit."
  }

  validation {
    condition     = !contains(keys(var.datasets), "tasks")
    error_message = "a dataset cannot be named `tasks`: `<name_root>-<project>-tasks` is the task results bucket, which the caller creates and expires."
  }

  validation {
    condition = alltrue(flatten([
      for dataset in values(var.datasets) : [
        for profile in concat(dataset.writer_profiles, keys(dataset.profile_grants)) : contains(keys(var.profiles), profile)
      ]
    ]))
    error_message = "datasets: every `writer_profiles` entry and every `profile_grants` key must be a profile in `profiles`."
  }
}
