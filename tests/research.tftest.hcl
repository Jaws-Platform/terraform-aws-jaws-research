# Every run is a plan, with the mocked values available at plan
# (override_during). A dataset bucket has prevent_destroy, so a run that
# applied one would leave the test a bucket it is not allowed to clean up.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id = "lt-0123456789abcdef0"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/acme-chess-bot-task"
    }
  }

  # Any security group but the cpu profile's own, which is overridden below:
  # a profile that wrongly created its own would show this ID.
  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-0ffffffffffffffff"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::acme-chess-bot-positions"
    }
  }
}

# The project's security group: the one the cpu profile creates.
override_resource {
  target          = module.task_runner.aws_security_group.this
  override_during = plan
  values = {
    id = "sg-0123456789abcdef0"
  }
}

variables {
  name_root = "acme"
  project   = "chess-bot"
  vpc_id    = "vpc-0123456789abcdef0"
}

run "one_cpu_profile_and_no_dataset_by_default" {
  command = plan

  assert {
    condition     = length(module.task_profile) == 0 && length(module.dataset_bucket) == 0
    error_message = "the defaults must create the cpu profile alone and no dataset bucket"
  }

  assert {
    condition = (
      output.launch_template_names == { cpu = "acme-chess-bot-task" } &&
      output.instance_role_names == { cpu = "acme-chess-bot-task" }
    )
    error_message = "the cpu profile's template and role must be <name_root>-<project>-task"
  }

  assert {
    condition = (
      output.launch_template_ids == { cpu = module.task_runner.launch_template_id } &&
      output.instance_profile_arns == { cpu = module.task_runner.instance_profile_arn } &&
      output.launch_template_ids["cpu"] == "lt-0123456789abcdef0"
    )
    error_message = "the template ID and instance profile ARN must be the task-runner module's outputs"
  }

  assert {
    condition = (
      output.security_group_id == module.task_runner.security_group_id &&
      output.security_group_id == "sg-0123456789abcdef0" &&
      output.log_group_name == "/acme/chess-bot/tasks"
    )
    error_message = "the security group and the log group must be the cpu profile's"
  }

  assert {
    condition = (
      output.results_bucket_name == "acme-chess-bot-tasks" &&
      output.results_uri == "s3://acme-chess-bot-tasks/tasks/" &&
      output.results_uri == module.task_runner.results_uri
    )
    error_message = "the results bucket name must be the bucket of the task-runner module's results URI"
  }

  assert {
    condition = (
      length(output.dataset_bucket_names) == 0 &&
      length(output.dataset_bucket_arns) == 0 &&
      length(output.dataset_uris) == 0
    )
    error_message = "the dataset outputs must be empty without datasets"
  }
}

run "a_second_profile_shares_the_log_group_and_security_group" {
  command = plan

  variables {
    profiles = {
      cpu = { rust_toolchain = "1.91.0" }
      gpu = {
        gpu                   = true
        ami_id                = "ami-0fedcba9876543210"
        default_instance_type = "g6.xlarge"
        root_volume_gb        = 200
        rust                  = false
      }
    }
  }

  assert {
    condition     = keys(module.task_profile) == ["gpu"] && module.task_profile["gpu"].profile == "gpu"
    error_message = "every profile but cpu must be its own task-runner, carrying its own name"
  }

  assert {
    condition     = module.task_runner.profile == "cpu"
    error_message = "the first profile must stay cpu, so that it keeps the project's log group and security group"
  }

  assert {
    condition = (
      output.launch_template_names == { cpu = "acme-chess-bot-task", gpu = "acme-chess-bot-task-gpu" } &&
      output.instance_role_names == { cpu = "acme-chess-bot-task", gpu = "acme-chess-bot-task-gpu" }
    )
    error_message = "another profile's template and role must be <name_root>-<project>-task-<profile>"
  }

  assert {
    condition = (
      output.launch_template_ids["gpu"] == module.task_profile["gpu"].launch_template_id &&
      output.instance_profile_arns["gpu"] == module.task_profile["gpu"].instance_profile_arn &&
      length(output.launch_template_ids) == 2 && length(output.instance_profile_arns) == 2
    )
    error_message = "the per-profile outputs must carry every profile's task-runner outputs"
  }

  assert {
    condition = (
      module.task_profile["gpu"].security_group_id == "sg-0123456789abcdef0" &&
      module.task_profile["gpu"].shared == module.task_runner.shared &&
      output.security_group_id == "sg-0123456789abcdef0" &&
      output.log_group_name == "/acme/chess-bot/tasks"
    )
    error_message = "another profile must reuse the cpu profile's log group and security group, not create its own"
  }
}

run "every_profile_setting_is_passed_through" {
  command = plan

  variables {
    log_retention_days = 30
    profiles = {
      cpu = {
        architecture          = "arm64"
        ami_id                = "ami-0fedcba9876543210"
        default_instance_type = "c8g.xlarge"
        root_volume_gb        = 80
        max_lifetime_hours    = 2
        rust                  = false
      }
      bench = {
        default_instance_type = "c8a.16xlarge"
        max_lifetime_hours    = 4
        rust_toolchain        = "1.91.0"
      }
    }
  }

  assert {
    condition     = keys(output.launch_template_names) == ["bench", "cpu"]
    error_message = "explicit settings must still plan one template per profile"
  }
}

run "dataset_buckets_with_profile_access" {
  command = plan

  variables {
    profiles = {
      cpu = {}
      gpu = { gpu = true }
    }
    datasets = {
      positions = {
        prefix           = "data/"
        writer_profiles  = ["cpu"]
        reader_role_arns = ["arn:aws:iam::123456789012:role/acme-ds-chess-bot-positions"]
        expire_prefixes  = { "tmp/" = 30 }
      }
      nets = {
        prefix                 = "data/"
        versioning             = true
        expire_noncurrent_days = 90
        transition_days        = 30
        profile_grants = {
          cpu = { read = ["nets/"] }
          gpu = { read = ["selfplay/"], write = ["logs/"], write_once = ["nets/"] }
        }
      }
    }
  }

  assert {
    condition     = keys(module.dataset_bucket) == ["nets", "positions"]
    error_message = "each datasets entry must create one dataset bucket"
  }

  assert {
    condition = output.dataset_bucket_names == {
      nets      = "acme-chess-bot-nets"
      positions = "acme-chess-bot-positions"
    }
    error_message = "a dataset bucket must be named <name_root>-<project>-<dataset>"
  }

  assert {
    condition = output.dataset_uris == {
      nets      = "s3://acme-chess-bot-nets/data/"
      positions = "s3://acme-chess-bot-positions/data/"
    }
    error_message = "a dataset's URI must be its bucket and prefix"
  }

  assert {
    condition = (
      output.dataset_bucket_arns["positions"] == module.dataset_bucket["positions"].arn &&
      output.dataset_bucket_arns["nets"] == module.dataset_bucket["nets"].arn &&
      length(output.dataset_bucket_arns) == 2
    )
    error_message = "the dataset ARNs must be the dataset-bucket module's outputs"
  }
}

run "rejects_profiles_without_cpu" {
  command = plan

  variables {
    profiles = {
      gpu = { gpu = true }
    }
  }

  expect_failures = [var.profiles]
}

run "rejects_a_dataset_named_tasks" {
  command = plan

  variables {
    datasets = {
      tasks = { prefix = "data/" }
    }
  }

  expect_failures = [var.datasets]
}

run "rejects_a_dataset_name_that_is_not_kebab_case" {
  command = plan

  variables {
    datasets = {
      Positions_v2 = { prefix = "data/" }
    }
  }

  expect_failures = [var.datasets]
}

# acme-chess-bot- is 15 characters, so 48 more is the 63 S3 allows.
run "accepts_a_dataset_bucket_name_of_63_characters" {
  command = plan

  variables {
    datasets = {
      a-dataset-name-that-is-forty-eight-characters-lo = { prefix = "data/" }
    }
  }

  assert {
    condition     = length(output.dataset_bucket_names["a-dataset-name-that-is-forty-eight-characters-lo"]) == 63
    error_message = "a 63-character bucket name must be accepted"
  }
}

run "rejects_a_dataset_bucket_name_of_64_characters" {
  command = plan

  variables {
    datasets = {
      a-dataset-name-that-is-forty-nine-characters-long = { prefix = "data/" }
    }
  }

  expect_failures = [var.datasets]
}

run "rejects_a_writer_profile_that_does_not_exist" {
  command = plan

  variables {
    datasets = {
      positions = { prefix = "data/", writer_profiles = ["gpu"] }
    }
  }

  expect_failures = [var.datasets]
}

run "rejects_a_grant_to_a_profile_that_does_not_exist" {
  command = plan

  variables {
    datasets = {
      positions = {
        prefix         = "data/"
        profile_grants = { gpu = { read = ["selfplay/"] } }
      }
    }
  }

  expect_failures = [var.datasets]
}

# The root's `profiles` and `datasets` types repeat the submodules' defaults:
# an attribute a caller leaves out has to become some value, and passing null
# to a submodule does not select its default. The next four runs pin both
# sides to the same values, so that changing a default in one place only
# fails here.
run "the_task_runner_defaults" {
  command = plan

  module {
    source = "./modules/task-runner"
  }

  assert {
    condition = (
      var.gpu == false && var.architecture == "x86_64" && var.ami_id == null &&
      var.default_instance_type == "c8a.xlarge" && var.root_volume_gb == 40 &&
      var.max_lifetime_hours == 6 && var.rust_toolchain == "stable" &&
      var.log_retention_days == 14
    )
    error_message = "a task-runner default changed: change the same default in the root's profiles type (or log_retention_days), and both of these runs"
  }
}

run "the_root_repeats_the_task_runner_defaults" {
  command = plan

  assert {
    condition = (
      var.profiles["cpu"].gpu == false && var.profiles["cpu"].architecture == "x86_64" &&
      var.profiles["cpu"].ami_id == null && var.profiles["cpu"].default_instance_type == "c8a.xlarge" &&
      var.profiles["cpu"].root_volume_gb == 40 && var.profiles["cpu"].max_lifetime_hours == 6 &&
      var.profiles["cpu"].rust == true && var.profiles["cpu"].rust_toolchain == "stable"
    )
    error_message = "a profile that sets nothing must get the task-runner module's defaults"
  }

  assert {
    condition     = var.log_retention_days == 14
    error_message = "log_retention_days must default to the task-runner module's default"
  }
}

run "the_dataset_bucket_defaults" {
  command = plan

  module {
    source = "./modules/dataset-bucket"
  }

  variables {
    name   = "acme-chess-bot-positions"
    prefix = "data/"
  }

  assert {
    condition = (
      var.transition_days == 0 && var.versioning == false && var.expire_noncurrent_days == null &&
      length(var.expire_prefixes) == 0 && length(var.reader_role_arns) == 0 &&
      length(var.writer_role_names) == 0 && length(var.role_grants) == 0
    )
    error_message = "a dataset-bucket default changed: change the same default in the root's datasets type, and both of these runs"
  }
}

run "the_root_repeats_the_dataset_bucket_defaults" {
  command = plan

  variables {
    datasets = {
      positions = { prefix = "data/" }
    }
  }

  assert {
    condition = (
      var.datasets["positions"].transition_days == 0 && var.datasets["positions"].versioning == false &&
      var.datasets["positions"].expire_noncurrent_days == null &&
      length(var.datasets["positions"].expire_prefixes) == 0 &&
      length(var.datasets["positions"].reader_role_arns) == 0 &&
      length(var.datasets["positions"].writer_profiles) == 0 &&
      length(var.datasets["positions"].profile_grants) == 0
    )
    error_message = "a dataset that sets only its prefix must get the dataset-bucket module's defaults"
  }
}
