#!/bin/bash
IMAGE="aivisp/slice.sip.app.v1.0"

# 1. Determine current active port and set target inactive port
if docker ps | grep -q "slice-blue"; then
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

echo "==> Deploying $TARGET_COLOR container on port $TARGET_PORT..."

# 2. Pull latest image and run target container
docker pull $IMAGE
docker run -d --name slice-$TARGET_COLOR -p $TARGET_PORT:80 $IMAGE

# 3. Perform Health Check
echo "==> Running health check on port $TARGET_PORT..."
HEALTHY=false
for i in {1..10}; do
    if curl -s -f http://localhost:$TARGET_PORT/ > /dev/null; then
        HEALTHY=true
        break
    fi
    echo "Attempt $i: App not ready yet, waiting 3 seconds..."
    sleep 3
done

# 4. Switch Traffic or Rollback
if [ "$HEALTHY" = true ]; then
    echo "==> Health check PASSED! Switching Nginx traffic to $TARGET_COLOR ($TARGET_PORT)."
    
    # Update Nginx active port configuration
    echo "set \$active_port $TARGET_PORT;" | sudo tee /etc/nginx/conf.d/active_port.conf
    sudo nginx -s reload

    # Clean up old container
    if [ "$(docker ps -a -q -f name=$OLD_CONTAINER)" ]; then
        echo "==> Stopping and removing old container ($OLD_CONTAINER)..."
        docker stop $OLD_CONTAINER
        docker rm $OLD_CONTAINER
    fi
    echo "==> Deployment successful!"
else
    echo "==> Health check FAILED! Rolling back..."
    docker stop slice-$TARGET_COLOR
    docker rm slice-$TARGET_COLOR
    exit 1
fi
