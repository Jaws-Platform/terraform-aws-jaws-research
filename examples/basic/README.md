# Basic: one task profile

The least a project needs to run tasks on ephemeral EC2 instances:

- a VPC with two public subnets, from the
  [network family](https://registry.terraform.io/modules/Jaws-Platform/jaws-network/aws/latest);
- the `cpu` task profile with every default: a launch template for
  `c8a.xlarge` instances on the latest Amazon Linux 2023 image, a write-only
  instance role, a security group without ingress and a log group;
- the results bucket the task instances write to, a
  [`private-bucket`](https://registry.terraform.io/modules/Jaws-Platform/jaws-foundation/aws/latest/submodules/private-bucket)
  whose objects expire after a week.

Nothing here launches an instance, and nothing here has a standing cost. A
launcher starts one instance per task from the launch template, into one of
the public subnets, and terminates it when the task ends.

```sh
terraform init
terraform plan
```

In your own configuration, replace the relative `source` with the registry
address, and the git sources with the other families' registry addresses:

```hcl
module "research" {
  source  = "Jaws-Platform/jaws-research/aws"
  version = "0.1.1" # x-release-please-version

  name_root = "acme"
  project   = "chess-bot"
  vpc_id    = module.network.vpc_id
}

module "task_results" {
  source  = "Jaws-Platform/jaws-foundation/aws//modules/private-bucket"
  version = "~> 0.1"

  name                           = module.research.results_bucket_name
  current_object_expiration_days = 7
}
```
