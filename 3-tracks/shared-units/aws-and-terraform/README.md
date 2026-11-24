# AWS and Terraform

> Shared unit · Time: 2 weeks at 12–15 hours a week · Builds on [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) and [Core 08 Shipping safely](../../../2-core/08-shipping-safely/README.md) · Used by the cloud and network track · Status: ready

## What you'll build

Describe a Switchyard deployment in Terraform. Put the jobs API behind an Application Load Balancer and run the API and worker as ECS Fargate tasks with PostgreSQL on RDS. Give the stack narrowly scoped IAM roles, an S3 artifact bucket, and an SQS queue with a dead-letter queue. Exercise the queue adapter locally and review the infrastructure as a Terraform plan. Keep the runnable gate independent of an AWS account.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Read what Terraform intends to change](lessons/01-read-the-plan.md) | Initialize a pinned provider, validate the configuration, and inspect resource actions and dependencies with a local fixture. Explain which artifacts and credentials belong outside version control. |
| 1 | 02 | [Put the load balancer at the network boundary](lessons/02-network-boundaries.md) | Define the VPC, subnets, routing, and security groups. Review which resources get public addresses and check the intended load balancer → API → database path. |
| 1 | 03 | [Give tasks a narrow identity](lessons/03-scoped-iam.md) | Separate ECS execution roles from application task roles. Define the S3 bucket, SQS queue, and dead-letter queue. Check the application role's allowed actions and resource scope. |
| 2 | 04 | [Run Switchyard on Fargate with RDS](lessons/04-run-fargate-with-rds.md) | Describe API and worker tasks, health checks, PostgreSQL, and the migration step. Review what happens to job ownership during a coordinator replacement. |
| 2 | 05 | [Exercise queue delivery and observe failures](lessons/05-delivery-and-observability.md) | Use a local SQS-compatible fixture to check receipt, acknowledgment, and redelivery without changing who owns job state. Add CloudWatch logs and alarms and a budget notification configuration. |
| 2 | 06 | [Review the plan and prove the policy checks](lessons/06-review-and-verify.md) | Run the offline gate, inspect the planned access paths, and catch an intentionally broadened access rule. Document apply, verify, and teardown as an optional cloud exercise. |

## The gate

Use the [automated gate](gate/README.md) to validate the configuration and run plan assertions with a mocked AWS provider. Check the public entry point, private tasks and database, role and resource scope, queue redrive, alarms, and budget configuration. Run the queue adapter against the local fixture and verify that a failed delivery returns without acknowledging the message.

A disposable variant that widens database ingress must fail the same plan assertion. The [optional cloud exercise](cloud-exercise.md) documents provisioning, verification, and teardown for learners using an AWS account. The unit's completion gate runs locally.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read a plan and explain which resources Terraform proposes to create. |
| Intermediate | Trace the request and database paths, and relate an IAM permission to the task that uses it. |
| Senior | Defend the deployment's trust, replacement, and cost boundaries with plan and runtime evidence. |

## Practice

- [Exercise](exercises.md). Review a second environment.
- [Self-check](self-check.md). Explain the plan and delivery behavior.
- [Evidence](evidence/README.md). Inspect the local checks and negative control.
