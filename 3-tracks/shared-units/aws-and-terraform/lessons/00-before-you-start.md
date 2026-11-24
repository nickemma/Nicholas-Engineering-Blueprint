# 00 Before you start

Use Terraform 1.10 or newer, Go from the core, Bash, and Python 3. Work in a fresh scratch directory. Export `blueprint` as the absolute path to this checkout before changing directories. Use Core 03's finished job service as the application source if you build images for the optional cloud exercise.

The first Terraform initialization retrieves the pinned provider, or uses a local mirror. The gate runs mock plans and a local SQS protocol fixture. It uses no AWS account.
