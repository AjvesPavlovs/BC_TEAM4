
#!/bin/bash

# Pre-deployment checks
# Terraform and Ansible are checked before deployment.
# Jenkins handles the application build and deployment.
# Existing AWS infrastructure is not modified here.

set -e

echo "Checking project files..."

for file in main.tf Jenkinsfile ansible/playbook.yml ansible/runansible.sh
do
    if [ ! -f "$file" ]; then
        echo "Missing file: $file"
        exit 1
    fi
done

echo "Checking Ansible..."

bash -n ansible/runansible.sh
ansible-playbook -i 'localhost,' ansible/playbook.yml --syntax-check

echo "Checking Terraform..."

terraform init -backend=false -input=false
terraform validate
terraform plan -refresh=false -input=false

echo "Checking AWS account..."

aws sts get-caller-identity --query Account --output text

echo "Pre-deployment checks completed."
