# 03 Give tasks a narrow identity

The ECS execution role lets the runtime pull images and ship logs. The API and migration execution role can also read the one RDS-managed secret. The independent one-shot delivery task has a separate execution role and a task role that can receive and delete from one SQS source queue. Identify the principal and resource for both actions.

The queue has a visibility interval and a dead-letter queue. The S3 artifact bucket blocks public access and encrypts stored objects. Explain how deleting a receipt differs from publishing a second copy of the same logical job.

### iam.tf

Create `infra/iam.tf`.

<!-- file: infra/iam.tf -->
~~~hcl
locals {
  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "execution" {
  name               = "switchyard-execution"
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "read-db-password"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_db_instance.main.master_user_secret[0].secret_arn
    }]
  })
}


resource "aws_iam_role" "delivery" {
  name               = "switchyard-delivery"
  assume_role_policy = local.ecs_tasks_trust
}
resource "aws_iam_role_policy" "delivery" {
  name = "delivery-queue-only"
  role = aws_iam_role.delivery.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
      Resource = aws_sqs_queue.main["delivery"].arn
    }]
  })
}
resource "aws_iam_role" "delivery_execution" {
  name               = "switchyard-delivery-execution"
  assume_role_policy = local.ecs_tasks_trust
}
resource "aws_iam_role_policy_attachment" "delivery_execution" {
  role       = aws_iam_role.delivery_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
~~~

### queues.tf

Create `infra/queues.tf`.

<!-- file: infra/queues.tf -->
~~~hcl
locals {
  queues = toset(["delivery"])
}

resource "aws_sqs_queue" "dead" {
  for_each                  = local.queues
  name                      = "switchyard-${each.key}-dead"
  message_retention_seconds = 1209600 # 14 days, the most SQS allows: time to look
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "main" {
  for_each = local.queues
  name     = "switchyard-${each.key}"
  # A received message is hidden for this long; deleted when handled, it
  # reappears for another try if not. Longer than a job may run.
  visibility_timeout_seconds = 60
  # Long polling: a receive waits up to 20 s for a message instead of
  # returning empty at once, which is cheaper and faster.
  receive_wait_time_seconds = 20
  sqs_managed_sse_enabled   = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead[each.key].arn
    maxReceiveCount     = 5
  })
}
~~~

### storage.tf

Create `infra/storage.tf`.

<!-- file: infra/storage.tf -->
~~~hcl
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "switchyard-artifacts-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}
~~~

## Check it

~~~bash
terraform -chdir=infra fmt -check -recursive
~~~

<!-- run: terraform -chdir=infra fmt -check -recursive -->
