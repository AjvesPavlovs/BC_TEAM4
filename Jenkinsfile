pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    parameters {
        string(
            name: 'DOCKERHUB_REPO',
            defaultValue: 'aivisp/slice.sip.app.v1.0',
            description: 'Docker Hub repository'
        )
        string(
            name: 'ECS_CLUSTER',
            defaultValue: 'slice-sip-cluster',
            description: 'ECS cluster name from Terraform'
        )
        string(
            name: 'ECS_SERVICE',
            defaultValue: 'slice-sip-service',
            description: 'ECS service name from Terraform'
        )
    }

    environment {
        AWS_REGION = 'eu-west-1'
    }

    stages {
        stage('Check inputs') {
            steps {
                sh '''
                    set -eu
                    test -n "$DOCKERHUB_REPO"
                    test -n "$ECS_CLUSTER"
                    test -n "$ECS_SERVICE"
                '''
            }
        }

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build image') {
            steps {
                sh '''
                    set -eu
                    IMAGE="$DOCKERHUB_REPO:$BUILD_NUMBER"
                    docker build --pull -t "$IMAGE" .
                    docker tag "$IMAGE" "$DOCKERHUB_REPO:latest"
                '''
            }
        }

        stage('Push to Docker Hub') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'dockerhub-creds',
                        usernameVariable: 'DOCKERHUB_USER',
                        passwordVariable: 'DOCKERHUB_TOKEN'
                    )
                ]) {
                    sh '''
                        set -eu
                        trap 'docker logout >/dev/null 2>&1 || true' EXIT
                        printf '%s' "$DOCKERHUB_TOKEN" |
                            docker login --username "$DOCKERHUB_USER" --password-stdin
                        docker push "$DOCKERHUB_REPO:$BUILD_NUMBER"
                        docker push "$DOCKERHUB_REPO:latest"
                    '''
                }
            }
        }

        stage('Deploy to ECS Fargate') {
            steps {
                sh '''
                    set -eu

                    aws ecs update-service \
                      --region "$AWS_REGION" \
                      --cluster "$ECS_CLUSTER" \
                      --service "$ECS_SERVICE" \
                      --force-new-deployment

                    aws ecs wait services-stable \
                      --region "$AWS_REGION" \
                      --cluster "$ECS_CLUSTER" \
                      --services "$ECS_SERVICE"

                    echo "ECS deployment completed."
                '''
            }
        }
    }
}
