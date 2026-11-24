# AWS and Terraform · Self-check

1. Explain what the lock file, plan, and state each record.
2. Draw the two directions of the ALB-to-API path. List the only planned ingress source to PostgreSQL.
3. Explain which ECS role receives the database secret and which role deletes an SQS message.
4. Why does the lab start both service counts at zero? What stops two API coordinators from overlapping during a replacement?
5. Explain why a failed handler leaves a receipt unacknowledged. What does a budget notification tell the operator?
6. Which policy check detected the altered database ingress? Which facts still need live AWS verification?
