# 06 Review the plan and prove the policy checks

Read the mock's generated identity overrides. Each one gives the plan a fixed value to use where AWS would normally provide an identifier. Compare the resource graph with your diagram. Find the assertions for TLS, private tasks, database ingress, queue permissions, redrive, and budgets.

The gate also builds a temporary configuration whose PostgreSQL ingress is widened. That intentionally altered plan must fail the same policy assertion. Use the [gate guide](../gate/README.md) to run the full check and consult the [optional cloud exercise](../cloud-exercise.md) before provisioning anything.

### plan.tftest.hcl

Create `infra/tests/plan.tftest.hcl`.

<!-- file: infra/tests/plan.tftest.hcl -->
~~~hcl
override_resource {
  target          = aws_security_group.api
  override_during = plan
  values          = { id = "sg-api" }
}
override_resource {
  target          = aws_security_group.db
  override_during = plan
  values          = { id = "sg-db" }
}

mock_provider "aws" {
  override_during = plan
  mock_resource "aws_db_instance" {
    defaults = {
      address = "switchyard.example.internal"
      master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fixture"
      }]
    }
  }
}
override_resource {
  target          = aws_subnet.tasks[0]
  override_during = plan
  values          = { id = "subnet-task1" }
}
override_resource {
  target          = aws_subnet.tasks[1]
  override_during = plan
  values          = { id = "subnet-task2" }
}
override_resource {
  target          = aws_iam_role.execution
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:role/execution" }
}
override_resource {
  target          = aws_iam_role.delivery_execution
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:role/delivery-execution" }
}
override_resource {
  target          = aws_iam_role.delivery
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:role/delivery" }
}
override_resource {
  target          = aws_sqs_queue.main["delivery"]
  override_during = plan
  values          = { arn = "arn:aws:sqs:us-east-1:123456789012:main" }
}
override_resource {
  target          = aws_sqs_queue.dead["delivery"]
  override_during = plan
  values          = { arn = "arn:aws:sqs:us-east-1:123456789012:dead" }
}

variables {
  image           = "123456789012.dkr.ecr.us-east-1.amazonaws.com/switchyard@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  migration_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/switchyard-migrations@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/fixture"
  client_cidr     = "198.51.100.10/32"
  alert_email     = "ops@example.invalid"
}
run "bootstrap_then_review" {
  command = plan
  assert {
    condition     = aws_ecs_service.api.desired_count == 0 && aws_ecs_service.worker.desired_count == 0
    error_message = "Run migrations before starting services."
  }
  assert {
    condition     = aws_lb_listener.https.protocol == "HTTPS" && aws_lb_listener.https.port == 443 && !aws_lb.main.internal && aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv4 == var.client_cidr
    error_message = "The internet-facing entry must terminate TLS."
  }
  assert {
    condition = (
      !aws_db_instance.main.publicly_accessible &&
      aws_db_instance.main.storage_encrypted &&
      length(aws_route_table.database.route) == 0 &&
      aws_vpc_security_group_ingress_rule.db_from_api.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.db_from_api.cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.db_from_api.referenced_security_group_id == aws_security_group.api.id &&
      aws_vpc_security_group_ingress_rule.db_from_api.security_group_id == aws_security_group.db.id &&
      aws_vpc_security_group_ingress_rule.db_from_api.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.db_from_api.to_port == 5432
    )
    error_message = "DATABASE_INGRESS: PostgreSQL must accept only the API security group."
  }
  assert {
    condition = (
      !one(aws_ecs_service.api.network_configuration).assign_public_ip &&
      !one(aws_ecs_service.worker.network_configuration).assign_public_ip &&
      toset(one(aws_ecs_service.api.network_configuration).subnets) == toset(aws_subnet.tasks[*].id)
    )
    error_message = "Tasks must stay in private application subnets."
  }
  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.delivery.policy).Statement[0].Action) == toset(["sqs:ReceiveMessage", "sqs:DeleteMessage"]) &&
      jsondecode(aws_iam_role_policy.delivery.policy).Statement[0].Resource == aws_sqs_queue.main["delivery"].arn &&
      aws_ecs_task_definition.delivery.task_role_arn == aws_iam_role.delivery.arn &&
      aws_ecs_task_definition.delivery.execution_role_arn != aws_ecs_task_definition.api.execution_role_arn
    )
    error_message = "The one-shot delivery task needs a task role scoped to its source queue."
  }
  assert {
    condition = (
      jsondecode(aws_sqs_queue.main["delivery"].redrive_policy).maxReceiveCount == 5 &&
      jsondecode(aws_sqs_queue.main["delivery"].redrive_policy).deadLetterTargetArn == aws_sqs_queue.dead["delivery"].arn &&
      aws_s3_bucket_public_access_block.artifacts.block_public_policy &&
      aws_s3_bucket_public_access_block.artifacts.block_public_acls &&
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets &&
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls
    )
    error_message = "Attach redrive and block public access to the artifact bucket."
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.dead_letters["delivery"].metric_name == "ApproximateNumberOfMessagesVisible" &&
      aws_cloudwatch_metric_alarm.api_errors.threshold == 0.0144 &&
      aws_budgets_budget.monthly[0].budget_type == "COST" &&
      length(aws_budgets_budget.monthly[0].notification) == 2
    )
    error_message = "Plan the operational alarms and spend notifications."
  }
}
run "after_migration" {
  command = plan
  variables {
    services_enabled = true
  }
  assert {
    condition = (
      aws_ecs_service.api.desired_count == 1 &&
      aws_ecs_service.worker.desired_count == 1 &&
      aws_ecs_service.api.deployment_minimum_healthy_percent == 0 &&
      aws_ecs_service.api.deployment_maximum_percent == 100 &&
      jsondecode(aws_ecs_task_definition.api.container_definitions)[0].image == var.image
    )
    error_message = "Start one coordinator, preserve the verified digest, and replace without overlapping coordinators."
  }
}
~~~

## Check it

~~~bash
bash "$blueprint/3-tracks/shared-units/aws-and-terraform/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/aws-and-terraform/gate/run.sh" "$PWD" -->
