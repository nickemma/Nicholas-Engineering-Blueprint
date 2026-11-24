# Rebuild with Tilt and plan a remote Kubernetes cluster

Use the [disposable kind cluster](workloads-and-rollouts.md) for Tilt. The second part uses Terraform or OpenTofu to build an EKS plan with a mock provider.

## 1. Make a source change reach kind

Build a single static page. Tilt scans the files included in its Docker build, loads the resulting image into kind, and updates the Deployment to that image. Use Tilt v0.37.7 for this lab. [Tiltfile guide](https://docs.tilt.dev/tiltfile_authoring.html)

Create `www/index.html`.

<!-- file: www/index.html -->
~~~~html
first build
~~~~

Create `Dockerfile`.

<!-- file: Dockerfile -->
~~~~dockerfile
FROM busybox:1.37
COPY www/ /www/
ENTRYPOINT ["httpd", "-f", "-p", "8080", "-h", "/www"]
~~~~

Create `dev.yaml`.

<!-- file: dev.yaml -->
~~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-dev
  namespace: tilt-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: platform-dev
  template:
    metadata:
      labels:
        app: platform-dev
    spec:
      containers:
        - name: http
          image: platform-dev
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
~~~~

Create `Tiltfile`.

<!-- file: Tiltfile -->
~~~~python
allow_k8s_contexts('kind-blueprint-platform-build')
docker_build('platform-dev', '.', only=['Dockerfile', 'www'])
k8s_yaml('dev.yaml')
k8s_resource('platform-dev', port_forwards=['18080:8080'])
~~~~

~~~~bash
test "$(kubectl config current-context)" = kind-blueprint-platform-build
kubectl create namespace tilt-lab
tilt ci --timeout 90s
kubectl -n tilt-lab get deploy platform-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
printf 'second build\n' > www/index.html
tilt ci --timeout 90s
kubectl -n tilt-lab rollout status deploy/platform-dev --timeout=60s
kubectl -n tilt-lab get deploy platform-dev -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n tilt-lab exec deploy/platform-dev -- wget -qO- http://127.0.0.1:8080/
kubectl delete namespace tilt-lab
~~~~

The image reference changed after the source edit and the Pod returned `second build`. To watch edits continuously, use `tilt up` in place of the two CI runs and visit the configured port forward.

## 2. Build and check one cloud plan

This EKS configuration takes two or more existing private subnets in distinct availability zones in one VPC. The subnets need egress for image downloads. The worker and control plane have separate IAM roles. Workers can use the private API endpoint and the operator's public access is limited to an IPv4 /32. One worker starts in a node group capped at two. The cap is an input to a node autoscaler. An autoscaler still needs to be installed and granted permission to change node capacity. [AWS EKS resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) · [Node autoscaling](https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/)

Create `cloud/main.tf`.

<!-- file: cloud/main.tf -->
~~~~hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "subnet_ids" {
  description = "Two or more private subnets across AZs in one existing VPC."
  type        = set(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Supply private subnets in at least two availability zones."
  }
}

variable "operator_cidr" {
  description = "The operator's public IPv4 address as a /32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_cidr)) && endswith(var.operator_cidr, "/32")
    error_message = "Use a single IPv4 address in CIDR notation."
  }
}

provider "aws" {
  region = var.region
}

locals {
  name = "blueprint-eks-lab"
  services = {
    control = "eks.amazonaws.com"
    workers = "ec2.amazonaws.com"
  }
  policies = {
    control = "AmazonEKSClusterPolicy"
    nodes   = "AmazonEKSWorkerNodePolicy"
    network = "AmazonEKS_CNI_Policy"
    images  = "AmazonEC2ContainerRegistryPullOnly"
  }
}

resource "aws_iam_role" "lab" {
  for_each = local.services

  name = "${local.name}-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lab" {
  for_each = local.policies

  role       = aws_iam_role.lab[each.key == "control" ? "control" : "workers"].name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_eks_cluster" "lab" {
  name     = local.name
  role_arn = aws_iam_role.lab["control"].arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.operator_cidr]
  }

  depends_on = [aws_iam_role_policy_attachment.lab]
}

resource "aws_eks_node_group" "lab" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "lab-workers"
  node_role_arn   = aws_iam_role.lab["workers"].arn
  subnet_ids      = var.subnet_ids
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  depends_on = [aws_iam_role_policy_attachment.lab]
}

output "cluster_name" {
  value = aws_eks_cluster.lab.name
}
~~~~

Create `cloud/tests/sandbox.tftest.hcl`.

<!-- file: cloud/tests/sandbox.tftest.hcl -->
~~~~hcl
mock_provider "aws" {}

run "network_and_capacity_boundaries" {
  command = plan

  variables {
    operator_cidr = "192.0.2.10/32"
    subnet_ids    = ["subnet-lab-a", "subnet-lab-b"]
  }

  assert {
    condition     = toset(aws_eks_cluster.lab.vpc_config[0].public_access_cidrs) == toset(["192.0.2.10/32"])
    error_message = "The public endpoint must be limited to the operator's address."
  }

  assert {
    condition     = aws_eks_cluster.lab.vpc_config[0].endpoint_private_access
    error_message = "The worker nodes need the private API path."
  }

  assert {
    condition     = aws_eks_node_group.lab.scaling_config[0].max_size == 2
    error_message = "The demo node group should be capped at two."
  }
}
~~~~

~~~~bash
terraform -chdir=cloud init -backend=false
terraform -chdir=cloud validate
terraform -chdir=cloud test
~~~~

You can substitute `tofu` for `terraform`. The reference run used Terraform and returned `1 passed, 0 failed` with no AWS calls. To see the boundary check fail, change the node group's maximum to three and rerun the test.

## 3. Use an authorized remote sandbox

If you have a sandbox account, suitable subnets, and a budget, supply real `subnet_ids`, `operator_cidr` and `region` in `cloud/sandbox.tfvars`. Run a real plan and review it. Apply only in that sandbox, then use a dedicated kubeconfig. Set `REGION` to the region in that variable file.

~~~~bash
terraform -chdir=cloud plan -var-file=sandbox.tfvars -out=sandbox.plan
terraform -chdir=cloud apply sandbox.plan
~~~~

~~~~bash
aws eks update-kubeconfig --region "$REGION" --name blueprint-eks-lab \
  --alias blueprint-eks-sandbox --kubeconfig "$PWD/eks-sandbox.kubeconfig"
kubectl --kubeconfig "$PWD/eks-sandbox.kubeconfig" --context blueprint-eks-sandbox get nodes
kubectl --kubeconfig "$PWD/eks-sandbox.kubeconfig" --context blueprint-eks-sandbox \
  auth can-i create deployments --namespace default
~~~~

Delete your test workload and destroy the stack from the same Terraform or OpenTofu state using `terraform -chdir=cloud destroy -var-file=sandbox.tfvars`. Verify that the cluster, node group and resources created by the lab are gone. The existing VPC remains owned by its original stack. The reference checked the mocked plan and stopped before cloud apply.
