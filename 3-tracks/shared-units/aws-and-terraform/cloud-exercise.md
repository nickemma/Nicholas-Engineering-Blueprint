# Optional · Run Switchyard in an AWS lab

Use a dedicated sandbox account and region. The local gate requires neither. Before provisioning, review the NAT, RDS, load balancer, and task costs for the chosen region. Budget notifications are alerts. Charges can continue until you remove the resources.

1. Build the two images with `bash ops/build-images.sh /path/to/core03 /path/to/rds-ca.pem switchyard:lab switchyard-migrations:lab`. Obtain the RDS CA bundle from AWS. Publish both images to your sandbox registry, record their digest references, and verify that they contain the expected application and migration files. [Amazon RDS certificates](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
2. Supply the image digests, a regional ACM certificate ARN, an approved client IPv4 CIDR, and the budget email in a local variable file. Point the certificate's DNS name to the resulting load balancer. Review the bootstrap plan with `services_enabled = false`, then apply the reviewed plan.
3. Run the migration from the Terraform outputs. Inspect the task's stopped reason and migration container exit code. Enable services only after exit code zero.

~~~bash
cluster=$(terraform -chdir=infra output -raw cluster)
task=$(terraform -chdir=infra output -raw migration_task)
network=$(terraform -chdir=infra output -raw migration_network)
aws ecs run-task --cluster "$cluster" --task-definition "$task" \
  --launch-type FARGATE --network-configuration "$network"
~~~

4. Review the next plan with `services_enabled = true`. After applying it, check target health and submit a synthetic job through the certificate's HTTPS name. Poll the job until completion and inspect the logs and budget notification settings. Separately, submit the synthetic notice `switchyard-delivery-check` to the delivery queue and run the one-shot delivery task on the private task network. Confirm it handles the notice and deletes its receipt. Use the delivery task's own role to consume it.
5. When finished, check the plan for destruction before removing the lab stack. Use the same backend and variables. Verify that the services, load balancer, NAT gateway, storage, and alarms are gone. Remove images or registry resources created separately for the lab. Preserve any evidence or data you need before teardown.

The sample uses a single coordinator and a single NAT gateway. The coordinator replacement policy trades continuous availability for clear ownership of job recovery. The shared API/migration database user is a lab convenience. Split runtime and migration permissions before adapting the design to production.
