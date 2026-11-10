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
            description: 'Docker Hub repozitorijs, piemēram, lietotajvards/slice-sip'
        )
        string(
            name: 'EC2_INSTANCE_ID',
            defaultValue: '',
            description: 'EC2 instance ID no terraform output instance_id'
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
                    test -n "$DOCKERHUB_REPO" || {
                        echo "Aizpildi parametru DOCKERHUB_REPO."
                        exit 1
                    }
                    test -n "$EC2_INSTANCE_ID" || {
                        echo "Aizpildi parametru EC2_INSTANCE_ID."
                        exit 1
                    }
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

        stage('Deploy to EC2 through SSM') {
            steps {
                sh '''
                    set -eu

                    IMAGE="$DOCKERHUB_REPO:$BUILD_NUMBER"
                    PARAMETERS=$(printf \
                      '{"commands":["docker pull %s","docker rm -f slice-sip || true","docker run -d --name slice-sip --restart unless-stopped -p 80:80 %s"]}' \
                      "$IMAGE" "$IMAGE")

                    COMMAND_ID=$(aws ssm send-command \
                      --region "$AWS_REGION" \
                      --instance-ids "$EC2_INSTANCE_ID" \
                      --document-name "AWS-RunShellScript" \
                      --comment "Deploy Slice & Sip build $BUILD_NUMBER" \
                      --parameters "$PARAMETERS" \
                      --query "Command.CommandId" \
                      --output text)

                    echo "SSM command: $COMMAND_ID"

                    for attempt in $(seq 1 30); do
                        STATUS=$(aws ssm get-command-invocation \
                          --region "$AWS_REGION" \
                          --command-id "$COMMAND_ID" \
                          --instance-id "$EC2_INSTANCE_ID" \
                          --query "Status" \
                          --output text 2>/dev/null || true)

                        case "$STATUS" in
                            Success)
                                echo "Deployment completed."
                                exit 0
                                ;;
                            Failed|TimedOut|Cancelled)
                                aws ssm get-command-invocation \
                                  --region "$AWS_REGION" \
                                  --command-id "$COMMAND_ID" \
                                  --instance-id "$EC2_INSTANCE_ID" \
                                  --query '{Status:Status,Details:StatusDetails,Error:StandardErrorContent}' \
                                  --output json || true
                                exit 1
                                ;;
                        esac

                        sleep 5
                    done

                    echo "Timed out waiting for the SSM deployment command."
                    exit 1
                '''
            }
        }
    }
}
