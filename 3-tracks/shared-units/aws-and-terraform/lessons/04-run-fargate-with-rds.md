# 04 Run Switchyard on Fargate with RDS

The cluster starts with service counts at zero. The operator runs the migration task and checks its exit status before enabling either service. The jobs API retains the single-coordinator assumption from Core 03. During a release it stops the prior coordinator before starting a new one, which introduces a short service gap but keeps startup recovery ownership clear. The worker resolves the coordinator using the private service name.

Terraform plans the database endpoint and secret identifier. ECS injects the password at runtime. The application and migration images carry an RDS CA bundle so both can verify the database hostname. Use image digests for the API and migration task. Build the jobs binaries from Core 03 and add the queue probe after Lesson 05.

### database.tf

Create `infra/database.tf`.

<!-- file: infra/database.tf -->
~~~hcl
resource "aws_db_subnet_group" "main" {
  name       = "switchyard"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = "switchyard-postgres17"
  family = "postgres17"

  # Refuse unencrypted connections.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  identifier        = "switchyard"
  engine            = "postgres"
  engine_version    = "17"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "switchyard"
  username = "switchyard"
  # RDS makes the password, keeps it in Secrets Manager and can rotate it.
  # It never appears in Terraform's state or in a task definition.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period   = 7
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "switchyard-final" : null
}
~~~

### ecs.tf

Create `infra/ecs.tf`.

<!-- file: infra/ecs.tf -->
~~~hcl
# ECS runs containers; Fargate runs them without servers to manage. A task
# definition is a Pod spec; a service is a Deployment.
locals {
  image = var.image
  # The database URL has no password; PGPASSWORD, read from Secrets
  # Manager when the task starts, supplies it (the PostgreSQL driver reads
  # it from the environment).
  database_url = "postgres://switchyard@${aws_db_instance.main.address}:5432/switchyard?sslmode=verify-full&sslrootcert=/rds-ca.pem"
  db_password  = [{ name = "PGPASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" }]
  logs = {
    for name in ["api", "worker", "migrate", "delivery"] : name => {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.service[name].name
        awslogs-region        = var.region
        awslogs-stream-prefix = name
      }
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = "switchyard"
  setting {
    name  = "containerInsights" # per-task CPU and memory, and RunningTaskCount
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(["api", "worker", "migrate", "delivery"])
  name              = "/switchyard/${each.key}"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "api" {
  family                   = "switchyard-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # each task gets its own network interface and IP, like a Pod
  cpu                      = 256      # a quarter of a vCPU
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "api"
    image        = local.image
    essential    = true
    portMappings = [{ containerPort = 8080 }]
    environment = [
      { name = "SWITCHYARD_DATABASE_URL", value = local.database_url },
      { name = "LISTEN_ADDR", value = "0.0.0.0:8080" },
      { name = "GRPC_ADDR", value = "0.0.0.0:9090" },
    ]
    secrets          = local.db_password
    stopTimeout      = 30 # SIGTERM, then this long before SIGKILL
    logConfiguration = local.logs["api"]
  }])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "switchyard-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.delivery_execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "worker"
    image            = local.image
    essential        = true
    entryPoint       = ["/worker"]
    environment      = [{ name = "CONTROL_PLANE", value = "api.${aws_service_discovery_private_dns_namespace.jobs.name}:9090" }]
    stopTimeout      = 30
    logConfiguration = local.logs["worker"]
  }])
}

# Run once per release, before updating the services: the Helm hook's job
# (step 7). The "migrate" output prints the command.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "switchyard-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name       = "migrate"
    image      = var.migration_image
    essential  = true
    entryPoint = ["psql"]
    command    = ["-X", "-v", "ON_ERROR_STOP=1", "-f", "/db/migrate.sql"]
    environment = [
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGUSER", value = "switchyard" },
      { name = "PGDATABASE", value = "switchyard" },
      { name = "PGSSLMODE", value = "verify-full" },
      { name = "PGSSLROOTCERT", value = "/rds-ca.pem" },
    ]
    secrets          = local.db_password
    logConfiguration = local.logs["migrate"]
  }])
}

resource "aws_ecs_service" "api" {
  name            = "api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.services_enabled ? 1 : 0
  launch_type     = "FARGATE"

  # Replace tasks without dropping below the desired count (step 7's
  # maxUnavailable: 0, maxSurge: 1)...
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  # ...and if new tasks keep failing, stop and roll back to the last
  # working task definition (step 7's --rollback-on-failure).
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = aws_subnet.tasks[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }
  service_registries {
    registry_arn = aws_service_discovery_service.api.arn
  }
  depends_on = [aws_lb_listener.https, aws_route_table_association.tasks]
}

resource "aws_ecs_service" "worker" {
  name            = "worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.services_enabled ? 1 : 0
  launch_type     = "FARGATE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = aws_subnet.tasks[*].id
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = false
  }
  depends_on = [aws_route_table_association.tasks]
}

resource "aws_service_discovery_private_dns_namespace" "jobs" {
  name = "switchyard.internal"
  vpc  = aws_vpc.main.id
}
resource "aws_service_discovery_service" "api" {
  name = "api"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.jobs.id
    dns_records {
      ttl  = 5
      type = "A"
    }
  }
}
resource "aws_ecs_task_definition" "delivery" {
  family                   = "switchyard-delivery"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.delivery_execution.arn
  task_role_arn            = aws_iam_role.delivery.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name       = "delivery"
    image      = var.image
    essential  = true
    entryPoint = ["/cloud-delivery"]
    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "DELIVERY_QUEUE_URL", value = aws_sqs_queue.main["delivery"].url },
    ]
    logConfiguration = local.logs["delivery"]
  }])
}
~~~

### outputs.tf

Create `infra/outputs.tf`.

<!-- file: infra/outputs.tf -->
~~~hcl

output "load_balancer_dns" {
  value = aws_lb.main.dns_name
}
output "cluster" {
  value = aws_ecs_cluster.main.name
}
output "migration_task" {
  value = aws_ecs_task_definition.migrate.arn
}
output "migration_network" {
  value = jsonencode({
    awsvpcConfiguration = {
      subnets        = aws_subnet.tasks[*].id
      securityGroups = [aws_security_group.api.id]
      assignPublicIp = "DISABLED"
    }
  })
}
output "delivery_queue_url" {
  value = aws_sqs_queue.main["delivery"].url
}
~~~

### app.Dockerfile

Create `ops/app.Dockerfile`.

<!-- file: ops/app.Dockerfile -->
~~~text
FROM scratch
COPY switchyard worker cloud-delivery /
COPY rds-ca.pem /
USER 65532:65532
ENTRYPOINT ["/switchyard"]
~~~

### migrations.Dockerfile

Create `ops/migrations.Dockerfile`.

<!-- file: ops/migrations.Dockerfile -->
~~~text
FROM postgres:17
COPY db /db
COPY rds-ca.pem /rds-ca.pem
USER 999:999
ENTRYPOINT ["psql"]
~~~

### build-images.sh

Create `ops/build-images.sh`.

<!-- file: ops/build-images.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
jobs=$(realpath "$1")
trust=$(realpath "$2")
app=$3
migrations=$4
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/app" "$work/migrate"
cp "$trust" "$work/app/rds-ca.pem"
cp "$trust" "$work/migrate/rds-ca.pem"
chmod 644 "$work/app/rds-ca.pem" "$work/migrate/rds-ca.pem"
for name in switchyard worker; do
  (cd "$jobs" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -buildvcs=false -trimpath -o "$work/app/$name" "./cmd/$name")
done
(cd queue && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -buildvcs=false -trimpath -o "$work/app/cloud-delivery" ./cmd/cloud-delivery)
cp -R "$jobs/db" "$work/migrate/db"
docker build --platform linux/amd64 -f ops/app.Dockerfile -t "$app" "$work/app"
docker build --platform linux/amd64 -f ops/migrations.Dockerfile -t "$migrations" "$work/migrate"
~~~

## Check it

~~~bash
terraform -chdir=infra fmt -check -recursive && bash -n ops/build-images.sh
~~~

<!-- run: terraform -chdir=infra fmt -check -recursive && bash -n ops/build-images.sh -->
