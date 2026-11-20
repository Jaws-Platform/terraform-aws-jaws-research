output "launch_template_names" {
  description = "Name of each profile's launch template, by profile: `<name_root>-<project>-task` for `cpu`, `<name_root>-<project>-task-<profile>` for the others. A launcher starts its `$Default` version."
  value       = { for name, profile in local.profiles : name => profile.launch_template_name }
}

output "launch_template_ids" {
  description = "ID of each profile's launch template, by profile."
  value       = { for name, profile in local.profiles : name => profile.launch_template_id }
}

output "instance_role_names" {
  description = "Name of each profile's instance role, by profile: the roles a launcher must be allowed to pass, and the ones the dataset grants are attached to."
  value       = { for name, profile in local.profiles : name => profile.instance_role_name }
}

output "instance_profile_arns" {
  description = "ARN of each profile's instance profile, by profile."
  value       = { for name, profile in local.profiles : name => profile.instance_profile_arn }
}

output "security_group_id" {
  description = "ID of the security group every profile's instances use: all egress, no ingress."
  value       = module.task_runner.security_group_id
}

output "log_group_name" {
  description = "CloudWatch log group every profile's tasks write their output to, `/<name_root>/<project>/tasks`."
  value       = module.task_runner.log_group_name
}

output "results_bucket_name" {
  description = "Name the task results bucket must have, `<name_root>-<project>-tasks`. This module does not create it: create a private bucket with this name, with an expiry that suits the project."
  # The task-runner module owns the name; it is the bucket of its results URI.
  value = regex("^s3://([^/]+)/", module.task_runner.results_uri)[0]
}

output "results_uri" {
  description = "S3 prefix under which each task's outputs land, as `<results_uri><role-id>:<instance-id>/`: an instance can write only its own."
  value       = module.task_runner.results_uri
}

output "dataset_bucket_names" {
  description = "Name of each dataset bucket, by dataset."
  value       = { for name, bucket in module.dataset_bucket : name => bucket.name }
}

output "dataset_bucket_arns" {
  description = "ARN of each dataset bucket, by dataset, for IAM policies."
  value       = { for name, bucket in module.dataset_bucket : name => bucket.arn }
}

output "dataset_uris" {
  description = "Where each dataset's data lives, by dataset: `s3://<bucket>/<prefix>`."
  value       = { for name, bucket in module.dataset_bucket : name => bucket.uri }
}
