pipeline {
    agent { label 'linux-docker' }

    options {
        skipDefaultCheckout()
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        string(name: 'DOCKERHUB_REPO', defaultValue: '', description: 'Approved public Docker Hub namespace/repository')
        booleanParam(name: 'DEPLOY', defaultValue: false, description: 'Publish the tested image and deploy to the configured Fargate environment')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    def commit = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
                    env.BUILD_TAG_SUFFIX = "${env.BUILD_NUMBER}-${commit}"
                    env.LOCAL_IMAGE = "slice-sip-ci:${env.BUILD_TAG_SUFFIX}"
                }
            }
        }

        stage('Verify Jenkins agent with Ansible') {
            steps {
                sh 'ansible-playbook -i localhost, ansible/verify-jenkins-agent.yml'
            }
        }

        stage('Validate Terraform') {
            steps {
                sh '''
                    set -eu
                    terraform -chdir=terraform-fargate fmt -check -recursive
                    terraform -chdir=terraform-fargate init -backend=false -input=false -lockfile=readonly
                    terraform -chdir=terraform-fargate validate
                    terraform -chdir=terraform-fargate test -no-color
                '''
            }
        }

        stage('Build and test image') {
            steps {
                sh '''
                    set -eu
                    docker build --pull --platform linux/amd64 -t "$LOCAL_IMAGE" .
                    container=$(docker run -d --rm -p 127.0.0.1::80 "$LOCAL_IMAGE")
                    trap 'docker stop "$container" >/dev/null 2>&1 || true' EXIT
                    address=$(docker port "$container" 80/tcp)
                    curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-all-errors --retry-delay 2 --max-time 10 "http://$address/" -o /dev/null
                '''
            }
        }

        stage('Verify deployment environment') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -eu
                    : "${FARGATE_BACKEND_CONFIG:?Set the path to the environment S3 backend config}"
                    : "${FARGATE_VARS_FILE:?Set the path to the environment tfvars}"
                    : "${TF_VAR_aws_account_id:?Set the expected AWS account ID}"
                    : "${TF_VAR_aws_region:?Set the AWS deployment region}"
                    test -r "$FARGATE_BACKEND_CONFIG"
                    test -r "$FARGATE_VARS_FILE"
                    printf '%s\n' "$DOCKERHUB_REPO" | grep -Eq '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9._-]*$'
                    account=$(aws sts get-caller-identity --region "$TF_VAR_aws_region" --query Account --output text)
                    test "$account" = "$TF_VAR_aws_account_id" || {
                        echo "Unexpected AWS account: $account" >&2
                        exit 1
                    }
                    terraform -chdir=terraform-fargate init -reconfigure -input=false -lockfile=readonly \
                        -backend-config="$FARGATE_BACKEND_CONFIG"
                '''
            }
        }

        stage('Publish versioned image') {
            when { expression { params.DEPLOY } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DOCKERHUB_USER', passwordVariable: 'DOCKERHUB_TOKEN')]) {
                    script {
                        env.APPLICATION_IMAGE = sh(returnStdout: true, script: '''
                            set -eu
                            DOCKER_CONFIG=$(mktemp -d)
                            export DOCKER_CONFIG
                            trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                            printf '%s' "$DOCKERHUB_TOKEN" |
                                docker login --username "$DOCKERHUB_USER" --password-stdin >&2
                            image="$DOCKERHUB_REPO:$BUILD_TAG_SUFFIX"
                            docker tag "$LOCAL_IMAGE" "$image"
                            result=$(docker push --platform linux/amd64 "$image") || { printf '%s\n' "$result" >&2; exit 1; }
                            printf '%s\n' "$result" >&2
                            digest=$(printf '%s\n' "$result" | awk '$2 == "digest:" {print $3}')
                            printf '%s\n' "$digest" | grep -Eq '^sha256:[a-f0-9]{64}$'
                            printf '%s@%s\n' "$DOCKERHUB_REPO" "$digest"
                        ''').trim()
                    }
                }
            }
        }

        stage('Deploy to Fargate') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -eu
                    cd terraform-fargate
                    plan=$(mktemp)
                    trap 'rm -f "$plan"' EXIT
                    terraform plan -input=false -lock-timeout=5m -var-file="$FARGATE_VARS_FILE" \
                        -var="aws_account_id=$TF_VAR_aws_account_id" -var="aws_region=$TF_VAR_aws_region" \
                        -var="application_image=$APPLICATION_IMAGE" -out="$plan"
                    terraform apply -input=false -lock-timeout=5m "$plan"
                '''
            }
        }

        stage('Verify Fargate release') {
            when { expression { params.DEPLOY } }
            steps {
                sh '''
                    set -eu
                    cd terraform-fargate
                    cluster=$(terraform output -raw ecs_cluster_name)
                    service=$(terraform output -raw ecs_service_name)
                    expected_revision=$(terraform output -raw task_definition_arn)
                    url=$(terraform output -raw application_url)
                    export AWS_DEFAULT_REGION="$TF_VAR_aws_region"
                    aws ecs wait services-stable --cluster "$cluster" --services "$service"
                    task=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" \
                        --desired-status RUNNING --query 'taskArns[0]' --output text)
                    test "$task" != None
                    running=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" \
                        --query "tasks[?lastStatus=='RUNNING'].[taskDefinitionArn, (containers[?name=='slice-sip'].imageDigest | [0])]" --output text)
                    expected=$(printf '%s\t%s' "$expected_revision" "${APPLICATION_IMAGE##*@}")
                    test "$running" = "$expected" || {
                        printf 'Expected revision and digest: %s\nActual: %s\n' "$expected" "$running" >&2
                        exit 1
                    }
                    curl --fail --silent --show-error --retry 6 --retry-all-errors \
                        --retry-delay 3 --max-time 10 "$url/" -o /dev/null
                    printf '%s\n' "$APPLICATION_IMAGE" "$expected_revision" "$url" | tee release.txt
                '''
                archiveArtifacts artifacts: 'terraform-fargate/release.txt'
            }
        }
    }
}
