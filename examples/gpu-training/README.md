# GPU training: two profiles and two datasets

A project that generates training data on CPU instances and trains on GPU
instances:

- a `cpu` profile for self-play and benchmarks (`c8a.16xlarge`, a pinned Rust
  toolchain) and a `gpu` profile for training (`g6.xlarge`, a pinned AWS Deep
  Learning image with the NVIDIA driver and CUDA, a 200 GB disk, no Rust).
  Each has its own launch template and instance role; they share one
  security group and one log group;
- a `positions` dataset that `cpu` instances add to and `gpu` instances read
  under `data/selfplay/`, with scratch files under `data/tmp/` expiring after
  30 days;
- a `nets` dataset that `gpu` instances add to under `data/nets/` and can
  never overwrite, versioned so that an administrator's mistake can be undone
  for 90 days;
- a VPC with public subnets and the results bucket, as in the
  [`basic`](https://github.com/Jaws-Platform/terraform-aws-jaws-research/tree/main/examples/basic)
  example.

`dataset_reader_role_arns` names further roles that may read the positions,
for example the role of a Databricks storage credential created by
[`databricks-dataset`](https://registry.terraform.io/modules/Jaws-Platform/jaws-databricks/aws/latest/submodules/databricks-dataset).
It is empty by default, because a bucket policy cannot name a role that does
not exist yet.

Nothing here launches an instance. Until a task runs and data lands in the
buckets, nothing here costs anything. The two dataset buckets have
`prevent_destroy`: `terraform destroy` fails while they are in state, on
purpose.

```sh
terraform init
terraform plan
```

In your own configuration, replace the relative `source` with the registry
address:

```hcl
module "research" {
  source  = "Jaws-Platform/jaws-research/aws"
  version = "0.1.0" # x-release-please-version

  name_root = "acme"
  project   = "chess-bot"
  vpc_id    = module.network.vpc_id

  profiles = {
    cpu = { default_instance_type = "c8a.16xlarge", rust_toolchain = "1.91.0" }
    gpu = {
      gpu                   = true
      ami_id                = data.aws_ami.deep_learning.id
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
      expire_prefixes = { "tmp/" = 30 }
    }
    nets = {
      prefix                 = "data/"
      profile_grants         = { gpu = { write_once = ["nets/"] } }
      versioning             = true
      expire_noncurrent_days = 90
    }
  }
}
```
