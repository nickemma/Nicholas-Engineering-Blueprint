# 02 Put the load balancer at the network boundary

Trace the public HTTPS route to the load balancer, then the HTTP target connection to the jobs API. The database trusts the API security group on TCP 5432, including its one-off migration task. The worker calls the coordinator on a distinct private gRPC port.

Place tasks in separate subnets without public IPs. Use one NAT gateway in this lab so private tasks can reach the registry and managed APIs. Database subnets use their own route table. Draw the allowed routes and explain how losing the NAT affects task startup. The ALB listener is public, and its security group admits the explicitly approved client CIDR.

### network.tf

Create `infra/network.tf`.

<!-- file: infra/network.tf -->
~~~hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true # RDS endpoints are DNS names
  tags                 = { Name = "switchyard" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index) # 10.20.0.0/24, 10.20.1.0/24
  tags              = { Name = "switchyard-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + count.index) # 10.20.10.0/24, 10.20.11.0/24
  tags              = { Name = "switchyard-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security groups are stateful firewalls around each kind of resource.
# Rules name other groups, not addresses: "the API's tasks", whatever IPs
# they have today.
resource "aws_security_group" "alb" {
  name   = "switchyard-alb"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.client_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "api" {
  name   = "switchyard-api"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "worker" {
  name   = "switchyard-worker" # no ingress rules: nothing calls a worker
  vpc_id = aws_vpc.main.id
}

# Tasks may call out anywhere: ECR, SQS, CloudWatch, Secrets Manager.
resource "aws_vpc_security_group_egress_rule" "tasks_out" {
  for_each          = { api = aws_security_group.api.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_security_group" "db" {
  name   = "switchyard-db"
  vpc_id = aws_vpc.main.id
}

# Only the API (and the migrate task, which uses the API's group) talks to
# the database. Workers don't need it.
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_subnet" "tasks" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 20 + count.index)
}
resource "aws_eip" "nat" {
  domain = "vpc"
}
resource "aws_nat_gateway" "egress" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "tasks" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.egress.id
  }
}
resource "aws_route_table_association" "tasks" {
  count          = 2
  subnet_id      = aws_subnet.tasks[count.index].id
  route_table_id = aws_route_table.tasks.id
}
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  route  = []
}
resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.database.id
}
resource "aws_vpc_security_group_ingress_rule" "rpc" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.worker.id
  from_port                    = 9090
  to_port                      = 9090
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_egress_rule" "rpc" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 9090
  to_port                      = 9090
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_egress_rule" "database" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
~~~

### loadbalancer.tf

Create `infra/loadbalancer.tf`.

<!-- file: infra/loadbalancer.tf -->
~~~hcl
resource "aws_lb" "main" {
  name                       = "switchyard"
  load_balancer_type         = "application"
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true

  internal = false
}

resource "aws_lb_target_group" "api" {
  name        = "switchyard-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
~~~

## Check it

~~~bash
terraform -chdir=infra fmt -check -recursive
~~~

<!-- run: terraform -chdir=infra fmt -check -recursive -->
