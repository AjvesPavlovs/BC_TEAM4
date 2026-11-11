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

        stage('Deploy to EC2 (Blue/Green via SSM)') {
            steps {
                sh '''
                    set -eu
                    IMAGE="$DOCKERHUB_REPO:$BUILD_NUMBER"

                    # Bash script executed on the EC2 instance via SSM
                    read -r -d '' DEPLOY_SCRIPT << 'EOF' || true
                    set -eu

                    IMAGE_TO_PULL="$1"

                    # 1. Determine active vs target color based on running containers
                    if docker ps --format '{{.Names}}' | grep -q "slice-blue"; then
                        CURRENT_COLOR="blue"
                        TARGET_COLOR="green"
                        TARGET_PORT=8082
                        OLD_CONTAINER="slice-blue"
                    else
                        CURRENT_COLOR="green"
                        TARGET_COLOR="blue"
                        TARGET_PORT=8081
                        OLD_CONTAINER="slice-green"
                    fi

                    echo "==> Pulling image: $IMAGE_TO_PULL"
                    docker pull "$IMAGE_TO_PULL"

                    echo "==> Starting target container slice-$TARGET_COLOR on port $TARGET_PORT..."
                    docker run -d --name "slice-$TARGET_COLOR" --restart unless-stopped -p "$TARGET_PORT:80" "$IMAGE_TO_PULL"

                    echo "==> Running health check on port $TARGET_PORT..."
                    HEALTHY=false
                    for i in $(seq 1 10); do
                        if curl -s -f "http://localhost:$TARGET_PORT/" > /dev/null; then
                            HEALTHY=true
                            break
                        fi
                        echo "Attempt $i: Container starting up, waiting 3 seconds..."
                        sleep 3
                    done

                    if [ "$HEALTHY" = true ]; then
                        echo "==> Health check passed! Switching Nginx traffic to port $TARGET_PORT."
                        
                        # Update Nginx active port config and reload
                        sudo mkdir -p /etc/nginx/conf.d
                        echo "set \$active_port $TARGET_PORT;" | sudo tee /etc/nginx/conf.d/active_port.conf
                        sudo nginx -s reload

                        if [ "$(docker ps -a -q -f name="$OLD_CONTAINER")" ]; then
                            echo "==> Stopping and removing old container ($OLD_CONTAINER)..."
                            docker stop "$OLD_CONTAINER"
                            docker rm "$OLD_CONTAINER"
                        fi
                        echo "==> Blue/Green deployment completed successfully!"
                    else
                        echo "==> Health check FAILED! Rolling back..."
                        docker stop "slice-$TARGET_COLOR"
                        docker rm "slice-$TARGET_COLOR"
                        exit 1
                    fi
EOF

                    # Escape and wrap parameters for AWS SSM
                    PARAMETERS=$(jq -n \
                      --arg cmd "$DEPLOY_SCRIPT bash -s $IMAGE" \
                      '{"commands([$cmd])}')

                    COMMAND_ID=$(aws ssm send-command \
                      --region "$AWS_REGION" \
                      --instance-ids "$EC2_INSTANCE_ID" \
                      --document-name "AWS-RunShellScript" \
                      --comment "Blue/Green Deploy Slice & Sip build $BUILD_NUMBER" \
                      --parameters "$PARAMETERS" \
                      --query "Command.CommandId" \
                      --output text)

                    echo "SSM command ID: $COMMAND_ID"

                    for attempt in $(seq 1 40); do
                        STATUS=$(aws ssm get-command-invocation \
                          --region "$AWS_REGION" \
                          --command-id "$COMMAND_ID" \
                          --instance-id "$EC2_INSTANCE_ID" \
                          --query "Status" \
                          --output text 2>/dev/null || true)

                        case "$STATUS" in
                            Success)
                                echo "SSM deployment finished successfully."
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