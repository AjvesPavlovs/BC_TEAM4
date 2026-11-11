#!/bin/bash
apt-get update -y
apt-get install -y docker.io nginx curl jq
systemctl start docker
systemctl enable docker

# Set up Nginx dynamic include structure
mkdir -p /etc/nginx/conf.d
echo "set \$active_port 8081;" > /etc/nginx/conf.d/active_port.conf

# Pull and start initial blue container
docker pull aivisp/slice.sip.app.v1.0:latest
docker run -d --name slice-blue --restart unless-stopped -p 8081:80 aivisp/slice.sip.app.v1.0:latest

# Restart Nginx to load configuration
systemctl restart nginx
systemctl enable nginx