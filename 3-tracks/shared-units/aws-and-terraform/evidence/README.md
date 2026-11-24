# AWS and Terraform · Evidence

The reference run used Terraform 1.15.8 and AWS provider 6.66.0. The [gate capture](gate.txt) shows validation, both mock plans, the SQS receipt test, and the expected failure of the widened-ingress variant.

The [clean lesson replay](replay.txt) rebuilt the unit and ran its checks from a new scratch directory.
