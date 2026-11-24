# 01 Read what Terraform intends to change

A Terraform resource describes intended state. A plan tells you how Terraform would reach it. State gives Terraform the identity of resources it already manages, so protect it like operational data. Keep local state, runtime inputs, and saved plans out of version control. Keep the provider lock file.

The gate uses the provider's real schema with a mock. In later lessons you will inspect explicit values directly and supply fixture identities for relationships that are normally known during provisioning. A mock plan helps test the configuration. It leaves AWS service behavior to the optional live exercise. [Terraform provider mocks](https://developer.hashicorp.com/terraform/language/tests/mocking)

### versions.tf

Create `infra/versions.tf`.

<!-- file: infra/versions.tf -->
~~~hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.66.0"
    }
  }
}
provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "switchyard-lab", managed-by = "terraform" }
  }
}
~~~

### .terraform.lock.hcl

Create `infra/.terraform.lock.hcl`.

<!-- file: infra/.terraform.lock.hcl -->
~~~hcl
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.66.0"
  constraints = "6.66.0"
  hashes = [
    "h1:hBEaeBm9nm7A/u1nnD0nfolTPP55/BoKRFWk8zG8/fk=",
    "zh:156fe7164a3d26ef6b35734c43e99fb198df90575ed897d1182b8e930b8cd523",
    "zh:1af52b22b35be00f8d16e3ebebff9fa699ec4db2ef69e6032ba5c536f80c03d9",
    "zh:2545a8478bd551fdc9694f6cc1a1ad24617f6736f8bde0ad6cae90987c65380f",
    "zh:4070db1ee369ccb41cb610bfd887386bc0a9b9ecad60aeb4dbce58443d2519dd",
    "zh:53da7d3c1840ef875c7d34e967732502a64fe677af0e78824773d4c15a8fe740",
    "zh:576a93a28bf611a4de2a2e6ced697a41d5126b8fd31d30782b16797e410a9706",
    "zh:58fed5fa9a033355b9d4f3092c817b70d934100e0d8678d6e4c93f3c9493d4e4",
    "zh:6a9ca2f24e2ee9156dd785d159a850b35d190e9cf7eca21cb9582970c2db80cd",
    "zh:729edd30f99cc16009deba5c013265b0c81eda261a3d0821cbd011d3287fd230",
    "zh:7ae460049b75bd4aefee465ef7c53a01ac2df46d4d3e3ac00824afa8b5cb83fb",
    "zh:9051fa85c8034ade8a57a5c6f232fd33da28f3800bb5aa40bc8625dbc5e27632",
    "zh:906547e4319805e7acf7fbdf2bac28a4b1a7370790a2a430c7adb1b29bb934eb",
    "zh:998f27410a66158a35ee5ed142c27e5b21fe8601941da55da2157f8042d6dcca",
    "zh:9b12af85486a96aedd8d7984b0ff811a4b42e3d88dad1a3fb4c0b580d04fa425",
    "zh:9c1804eff1dda0446dc2d215231015bb65a2fc6c3b7ba24584fe45f1ddd3fa9f",
    "zh:b03ff5efdee310502aaaeb460144dc059bce72a0d8217e6b989099ef8aef9283",
  ]
}
~~~

### .gitignore

Create `infra/.gitignore`.

<!-- file: infra/.gitignore -->
~~~text
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
*.tfplan
~~~

### variables.tf

Create `infra/variables.tf`.

<!-- file: infra/variables.tf -->
~~~hcl
variable "region" {
  description = "AWS region to build in."
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Two zones in the region. Named here rather than looked up, so plan works offline."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Give exactly two availability zones: the load balancer and the database subnets need two."
  }
}

variable "image" {
  type = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Use a pinned image digest."
  }
}
variable "migration_image" {
  type = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.migration_image))
    error_message = "Use a pinned migration image digest."
  }
}
variable "certificate_arn" {
  type = string
}
variable "services_enabled" {
  type    = bool
  default = false
}
variable "alert_email" {
  type    = string
  default = ""
}
variable "monthly_budget_usd" {
  type    = number
  default = 50
}
variable "deletion_protection" {
  type    = bool
  default = false
}
variable "client_cidr" {
  type        = string
  description = "IPv4 CIDR permitted to reach the public HTTPS listener."
  validation {
    condition     = can(cidrnetmask(var.client_cidr)) && !endswith(var.client_cidr, "/0")
    error_message = "Supply a specific approved IPv4 client range."
  }
}
~~~

## Check it

~~~bash
terraform -chdir=infra fmt -check -recursive
~~~

<!-- run: terraform -chdir=infra fmt -check -recursive -->
