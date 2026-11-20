# terraform-aws-jaws-research

[![Terraform Registry](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fregistry.terraform.io%2Fv1%2Fmodules%2FJaws-Platform%2Fjaws-research%2Faws&query=%24.version&prefix=v&label=registry&logo=terraform&color=7B42BC)](https://registry.terraform.io/modules/Jaws-Platform/jaws-research/aws/latest)
[![GitHub release](https://img.shields.io/github/v/release/Jaws-Platform/terraform-aws-jaws-research?label=release)](https://github.com/Jaws-Platform/terraform-aws-jaws-research/releases/latest)
[![CI](https://github.com/Jaws-Platform/terraform-aws-jaws-research/actions/workflows/ci.yml/badge.svg?event=pull_request)](https://github.com/Jaws-Platform/terraform-aws-jaws-research/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Jaws-Platform/terraform-aws-jaws-research/blob/main/LICENSE)

What a research project needs in an AWS account to run compute-heavy work
from CI and keep what it produces: launch templates for **ephemeral EC2 task
instances** (CPU instances for benchmarks, GPU instances for training) and
**kept-forever, append-only S3 buckets** for the datasets those tasks build
and read. Nothing here launches an instance, and nothing here costs money
until tasks run and data lands.

It is one of the [Jaws](https://github.com/jwallace145/jaws) module families.
In Jaws, a CLI run from a GitHub Actions workflow starts one instance per
task, runs the task on it through SSM Run Command and terminates it. The
modules have no dependency on Jaws: everything is a plain input, and any
launcher that does the same can use them.

## What it creates

```text
 CI job ──► launcher, for example the Jaws CLI        (not part of this module)
              │  RunInstances from a profile's launch template, into one of
              │  your public subnets: one instance per task, terminated after it
              ▼
 ┌─ this module ────────────────────────────────────────────────────────────┐
 │                                                                          │
 │  per profile: cpu, gpu, ...                                              │
 │  ┌───────────────────────────────┐   ┌────────────────────────────────┐  │
 │  │ launch template               │   │ instance role and profile      │  │
 │  │ IMDSv2, encrypted volume,     │   │ writes task logs and its own   │  │
 │  │ shuts down after a set time,  │   │ results; reads no secret, no   │  │
 │  │ and a shutdown terminates     │   │ parameter, no earlier result   │  │
 │  └───────────────────────────────┘   └────────────────────────────────┘  │
 │                                                                          │
 │  per project                                                             │
 │  ┌───────────────────────────────┐   ┌────────────────────────────────┐  │
 │  │ security group                │   │ log group                      │  │
 │  │ all egress, no ingress        │   │ /<name_root>/<project>/tasks   │  │
 │  └───────────────────────────────┘   └────────────────────────────────┘  │
 │                                                                          │
 │  per dataset: zero or more                                               │
 │  ┌────────────────────────────────────────────────────────────────────┐  │
 │  │ S3 bucket <name_root>-<project>-<dataset>                          │  │
 │  │ nothing expires, Intelligent-Tiering, prevent_destroy              │  │
 │  │ profiles add under a prefix, or read and add by sub-prefix;        │  │
 │  │ named roles read                                                   │  │
 │  └────────────────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────────┘

 Yours, passed in or created beside it: the VPC and its public subnets, and
 the results bucket <name_root>-<project>-tasks
```

Only the `cpu` profile is created by default: one launch template, one
instance role and profile, the security group and the log group. Every other
profile and every dataset bucket is opt-in.

## Modules

| Module | Creates |
|---|---|
| [root](https://registry.terraform.io/modules/Jaws-Platform/jaws-research/aws/latest) | One project in one call: a `task-runner` per profile, sharing one security group and one log group, and a `dataset-bucket` per dataset, with the profiles' instance roles granted access to it. |
| [`task-runner`](https://registry.terraform.io/modules/Jaws-Platform/jaws-research/aws/latest/submodules/task-runner) | One task profile: a launch template (a lifetime guard, terminate on shutdown, IMDSv2, an encrypted root volume), a write-only instance role and profile and, for a project's first profile, the no-ingress security group and the log group. It launches nothing. |
| [`dataset-bucket`](https://registry.terraform.io/modules/Jaws-Platform/jaws-research/aws/latest/submodules/dataset-bucket) | A kept-forever, append-only S3 bucket: no expiry, Intelligent-Tiering, `prevent_destroy`, add-only access for writer roles under one prefix, narrower grants by sub-prefix (optionally write-once), and read access for named roles. |

## Usage

One profile with every default, and the results bucket its instances write
to. The module names that bucket; you create it:

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

A GPU profile beside it, and two datasets: CPU tasks add positions, GPU
tasks read them and add nets that can never be overwritten:

```hcl
module "research" {
  source  = "Jaws-Platform/jaws-research/aws"
  version = "0.1.1" # x-release-please-version

  name_root = "acme"
  project   = "chess-bot"
  vpc_id    = module.network.vpc_id

  profiles = {
    cpu = { rust_toolchain = "1.91.0" }
    gpu = {
      gpu                   = true
      ami_id                = data.aws_ami.deep_learning.id # ships the NVIDIA driver and CUDA
      default_instance_type = "g6.xlarge"
      root_volume_gb        = 200
      rust                  = false
    }
  }

  datasets = {
    positions = {
      prefix          = "data/"
      writer_profiles = ["cpu"]
      profile_grants  = { gpu = { read = ["selfplay/"] } }
    }
    nets = {
      prefix         = "data/"
      profile_grants = { gpu = { write_once = ["nets/"] } }
    }
  }
}
```

`cpu` is always there: it is the project's first profile, and it owns the
security group and the log group that the others share.

Each submodule can also be used on its own, for example a dataset bucket that
no task writes to, read by a role you already have:

```hcl
module "nnue" {
  source  = "Jaws-Platform/jaws-research/aws//modules/dataset-bucket"
  version = "0.1.1" # x-release-please-version

  name             = "acme-chess-bot-nnue"
  prefix           = "data/"
  reader_role_arns = ["arn:aws:iam::123456789012:role/acme-chess-bot-train"]
}
```

## Launching tasks

Nothing in this repository calls `RunInstances`. A launcher does, with the
outputs of this module:

1. it starts an instance from `launch_template_names[<profile>]` (the
   `$Default` version), passing one of the VPC's public subnets and, if it
   wants, an instance type and spot options. The template brings the image,
   the instance profile, the security group, the disk and the setup;
2. it sends the task with SSM Run Command once setup has written
   `/etc/task-runner/ready`, with the task's output streamed to
   `log_group_name`;
3. the task writes what it wants kept under
   `<results_uri><role-id>:<instance-id>/`, the only place in the results
   bucket its instance can write, and adds to the datasets its profile was
   granted;
4. it terminates the instance. If it never does, the instance shuts itself
   down `max_lifetime_hours` after boot, and that terminates it.

In Jaws the launcher is the CLI's `jaws task run`, and the role it runs as
comes from the
[CI family](https://registry.terraform.io/modules/Jaws-Platform/jaws-ci/aws/latest):
[`ci-task-role`](https://registry.terraform.io/modules/Jaws-Platform/jaws-ci/aws/latest/submodules/ci-task-role)
with the `task/launch` policy of
[`ci-policies`](https://registry.terraform.io/modules/Jaws-Platform/jaws-ci/aws/latest/submodules/ci-policies).
That policy can launch only from this project's templates, only an
allow-list of instance types and only Amazon-owned images, pass only the
profiles' instance roles, and read only this project's task output. The same
catalog has the read and manage policies for CI roles that plan and apply
these resources (`task/*` and `dataset/*`; its README says what each covers).

## Sharing a dataset

`reader_role_arns` names the roles that may read a dataset, through its
bucket policy: a training role in another project, or the role of a
Databricks storage credential. The
[Databricks family](https://registry.terraform.io/modules/Jaws-Platform/jaws-databricks/aws/latest)
creates that role and a read-only Unity Catalog external location over the
prefix with
[`databricks-dataset`](https://registry.terraform.io/modules/Jaws-Platform/jaws-databricks/aws/latest/submodules/databricks-dataset),
and decides which workspaces may read it with
[`databricks-dataset-access`](https://registry.terraform.io/modules/Jaws-Platform/jaws-databricks/aws/latest/submodules/databricks-dataset-access).
The role can read nothing until the bucket names it here, so the project that
owns the data holds the switch.

## Examples

- [`basic`](https://github.com/Jaws-Platform/terraform-aws-jaws-research/tree/main/examples/basic):
  one `cpu` profile with every default, its VPC and its results bucket.
- [`gpu-training`](https://github.com/Jaws-Platform/terraform-aws-jaws-research/tree/main/examples/gpu-training):
  a `cpu` and a `gpu` profile, a dataset of positions and a write-once
  dataset of nets.

## Cost

Applying this module costs nothing, and it costs nothing while it sits idle:
it starts no instance, and an empty bucket and an empty log group are free.
Money is spent once tasks run and data lands:

| | us-east-1 |
|---|---|
| Launch templates, instance roles and profiles, the security group, an empty log group, empty dataset buckets | free |
| A task instance, from launch to termination | its on-demand or spot price: about $0.20 an hour on demand for the default `c8a.xlarge`, about $3.45 for a `c8a.16xlarge` (about $0.93 to $1.40 on spot), about $1.86 for a `g6e.xlarge` GPU instance |
| Its root volume and its public IPv4 address, while it exists | about $0.004 an hour for the default 40 GB, and $0.005 an hour |
| Task output in the log group | $0.50 per GB ingested, then $0.03 per GB a month until `log_retention_days` |
| Datasets | S3 Intelligent-Tiering: $0.023 per GB a month at first and less as data goes cold, plus $0.0025 a month per 1,000 objects of 128 KB or more. Nothing expires, so this only grows |
| Task results | S3 Standard in your results bucket, until the expiry you set |

The launcher chooses spot or on demand, and the instance type, per launch.
An instance that nothing terminates runs until its lifetime guard fires: six
hours by default, so about $1.20 for a `c8a.xlarge` and about $21 for a
`c8a.16xlarge`. What bounds the hourly price is the launch role's allow-list
of instance types, not this module. Data transfer out to the internet is
billed as usual. The figures are approximate list prices at the time of
writing; the [AWS pricing pages](https://aws.amazon.com/pricing/) are the
reference.

## What to know before using it

- **`us-east-1` only.** It is the only region these modules are used and
  tested in, and the prices above are its prices.
- **You create the results bucket**, named `results_bucket_name`
  (`<name_root>-<project>-tasks`). Each instance role may put objects under
  its own `tasks/<role-id>:<instance-id>/` prefix of it and nowhere else.
  Without the bucket, tasks run but cannot save results. Give it an expiry.
- **Instances need a way out to the internet** for packages, the code under
  test, SSM and S3. The intended home is a public subnet: there is no ingress
  rule and no SSH key, so a public address makes an instance no more
  reachable. Session Manager works for debugging.
- **Launching with the CI family needs the `Project` tag.** Its `task/launch`
  policy finds the launch templates, the security group and the subnets by
  the tag `Project = <project>`. The modules do not set it: put it in the
  provider's `default_tags`, on this stack and on the VPC's.
- **Spot needs the EC2 Spot service-linked role** in the account before the
  first spot launch, and a launch role should not be able to create it.
  [`service-linked-role`](https://registry.terraform.io/modules/Jaws-Platform/jaws-foundation/aws/latest/submodules/service-linked-role)
  creates it, once per account.
- **A task instance can only write.** Tasks run pull request code, so the
  instance role reads no parameter, no secret, no image and no earlier
  result. It reads a dataset only under the sub-prefixes a `profile_grants`
  entry names.
- **The guards bound accidents, not abuse.** Task code runs as root and could
  cancel the scheduled shutdown. The launcher's own termination is the
  primary cleanup; the lifetime guard is the backstop.
- **Without a pinned `ami_id` a profile follows the latest Amazon Linux 2023
  image**, and an apply after a new release moves the template to it. Pin
  the image and the Rust toolchain for reproducible task environments. Setup
  expects Amazon Linux 2023 (`dnf`).
- **A dataset bucket is permanent.** It has `prevent_destroy`: removing a
  dataset from `datasets`, or destroying the stack, fails at plan until the
  bucket's resources are removed from state, and the bucket then stays in the
  account. Its name is `<name_root>-<project>-<dataset>` and cannot change.
- **Append-only goes as far as the grants do.** No writer and no grant can
  delete, and a writer cannot read back. A plain writer can still put an
  object over an existing key (new data is expected to get new keys); only
  `write_once` sub-prefixes refuse that. An administrator's own policies can
  change or delete anything. Turn on `versioning` where that must be
  recoverable.
- **Reader roles must exist first.** S3 rejects a bucket policy that names a
  role that does not exist yet.
- **For anything the root does not cover, use the submodules.** The root
  always creates the `cpu` profile, derives every bucket name, and gives
  write and per-prefix access to the profiles' own roles only.
  `dataset-bucket` takes any bucket name and any role, and `task-runner`
  alone is enough for a project without datasets.
- **Providers are never configured here.** The caller configures `aws`.
- **Tags.** Every taggable resource gets `Name` and `Component` from its
  module, and launched instances and volumes get `Project`, `Component`,
  `Purpose` and `Profile` from the launch template. Every other tag comes
  from the caller's provider `default_tags`; the modules take no tag map.

The submodule READMEs have the details: what setup installs, the launch
contract, the instance role's exact permissions, and how dataset access and
write-once grants are enforced.

## Development

See [CONTRIBUTING.md](https://github.com/Jaws-Platform/terraform-aws-jaws-research/blob/main/CONTRIBUTING.md)
for local setup, the commit and pull request rules, CI, and how releases work.
`scripts/check.sh` runs everything CI runs, with no AWS credentials.

## Root module reference

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11 |
| aws | ~> 6.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| dataset\_bucket | ./modules/dataset-bucket | n/a |
| task\_profile | ./modules/task-runner | n/a |
| task\_runner | ./modules/task-runner | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name\_root | Prefix of every name, in kebab-case, usually the organisation: for example `acme`. Each profile's launch template, instance role and instance profile are `<name_root>-<project>-task` (with `-<profile>` appended for every profile but `cpu`), the log group is `/<name_root>/<project>/tasks`, the results bucket the caller creates is `<name_root>-<project>-tasks`, and each dataset bucket is `<name_root>-<project>-<dataset>`. | `string` | n/a | yes |
| project | Project in kebab-case, for example `chess-bot`. Every name derives from it and `name_root`, and task instances and their volumes carry it as the `Project` tag. | `string` | n/a | yes |
| vpc\_id | VPC of the task security group. The launch templates set no subnet: the launcher passes one of this VPC's public subnets with each launch. | `string` | n/a | yes |
| datasets | Dataset buckets by name, for example `positions`. Each is a kept-forever, append-only bucket named `<name_root>-<project>-<name>`, whose data lives under `prefix` (for example `data/`). `writer_profiles` lists the profiles whose instances may add objects anywhere under the prefix; they can never read or delete. `profile_grants` gives a profile narrower access, by sub-prefix of `prefix`: `read`, `write` (add) and `write_once` (add, and never overwrite). `reader_role_arns` are existing IAM roles that may read the prefix, such as another project's training role or the role of a Databricks storage credential. `transition_days`, `versioning`, `expire_noncurrent_days` and `expire_prefixes` are the `dataset-bucket` inputs of the same names. A bucket has `prevent_destroy`, so removing its entry fails the plan until the bucket is taken out of state. `tasks` cannot be a dataset: `<name_root>-<project>-tasks` is the task results bucket. | <pre>map(object({<br/>    prefix          = string<br/>    writer_profiles = optional(list(string), [])<br/>    profile_grants = optional(map(object({<br/>      read       = optional(list(string), [])<br/>      write      = optional(list(string), [])<br/>      write_once = optional(list(string), [])<br/>    })), {})<br/>    reader_role_arns       = optional(list(string), [])<br/>    transition_days        = optional(number, 0)<br/>    versioning             = optional(bool, false)<br/>    expire_noncurrent_days = optional(number)<br/>    expire_prefixes        = optional(map(number), {})<br/>  }))</pre> | `{}` | no |
| log\_retention\_days | Days CloudWatch keeps task output in the project's log group: one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180 or 365. | `number` | `14` | no |
| profiles | Task profiles by name, for example `cpu` for benchmarks and `gpu` for training. Each gets its own launch template, instance role and instance profile, so its image, disk and permissions are its own. `cpu` is required: it is the project's first profile, and it creates the log group and the security group that every other profile shares. `gpu` makes setup wait for the NVIDIA driver, and needs an image that ships the driver and CUDA, such as the AWS Deep Learning Base GPU AMI. `architecture` is `x86_64` or `arm64`. `ami_id` pins an Amazon Linux 2023 image; null follows the latest one for the architecture. `default_instance_type` is the template's type, which a launcher can override per launch. `root_volume_gb` sizes the encrypted root volume, from 20 to 200. `max_lifetime_hours`, from 1 to 24, is how long after boot an instance shuts itself down, and so terminates. `rust_toolchain` is the rustup toolchain that setup installs, and `rust = false` installs none. Profile names are kebab-case, at most 16 characters. | <pre>map(object({<br/>    gpu                   = optional(bool, false)<br/>    architecture          = optional(string, "x86_64")<br/>    ami_id                = optional(string)<br/>    default_instance_type = optional(string, "c8a.xlarge")<br/>    root_volume_gb        = optional(number, 40)<br/>    max_lifetime_hours    = optional(number, 6)<br/>    rust                  = optional(bool, true)<br/>    rust_toolchain        = optional(string, "stable")<br/>  }))</pre> | <pre>{<br/>  "cpu": {}<br/>}</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| dataset\_bucket\_arns | ARN of each dataset bucket, by dataset, for IAM policies. |
| dataset\_bucket\_names | Name of each dataset bucket, by dataset. |
| dataset\_uris | Where each dataset's data lives, by dataset: `s3://<bucket>/<prefix>`. |
| instance\_profile\_arns | ARN of each profile's instance profile, by profile. |
| instance\_role\_names | Name of each profile's instance role, by profile: the roles a launcher must be allowed to pass, and the ones the dataset grants are attached to. |
| launch\_template\_ids | ID of each profile's launch template, by profile. |
| launch\_template\_names | Name of each profile's launch template, by profile: `<name_root>-<project>-task` for `cpu`, `<name_root>-<project>-task-<profile>` for the others. A launcher starts its `$Default` version. |
| log\_group\_name | CloudWatch log group every profile's tasks write their output to, `/<name_root>/<project>/tasks`. |
| results\_bucket\_name | Name the task results bucket must have, `<name_root>-<project>-tasks`. This module does not create it: create a private bucket with this name, with an expiry that suits the project. |
| results\_uri | S3 prefix under which each task's outputs land, as `<results_uri><role-id>:<instance-id>/`: an instance can write only its own. |
| security\_group\_id | ID of the security group every profile's instances use: all egress, no ingress. |
<!-- END_TF_DOCS -->

## License

[MIT](https://github.com/Jaws-Platform/terraform-aws-jaws-research/blob/main/LICENSE)
