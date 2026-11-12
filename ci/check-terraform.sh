#!/bin/sh
set -eu

terraform -chdir=terraform-fargate fmt -check -recursive
terraform -chdir=terraform-fargate init -backend=false -input=false -lockfile=readonly
terraform -chdir=terraform-fargate validate
terraform -chdir=terraform-fargate test -no-color
