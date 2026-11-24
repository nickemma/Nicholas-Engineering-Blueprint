# AWS and Terraform gate

From the lesson scratch directory, run `bash "$blueprint/3-tracks/shared-units/aws-and-terraform/gate/run.sh" "$PWD"`. Terraform uses the locked provider schema. For offline initialization, point `SWITCHYARD_AWS_PLUGIN_DIR` at a local mirror with the pinned provider. Terraform spawns a local provider subprocess, which needs permission to open a local socket.

The gate validates the configuration, runs two mocked plans, exercises the SQS client against a local protocol fixture, and checks that a temporary variant with widened database ingress fails the specific policy assertion. The fixture verifies receipt handling and models a subsequent delivery. It does not measure SQS visibility timing. [Reference capture](../evidence/gate.txt)
