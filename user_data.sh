#!/bin/bash
apt-get update -y
apt-get install -y docker.io git curl

# Start and enable Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Configure SSH daemon to listen on port 443
echo "Port 443" >> /etc/ssh/sshd_config
systemctl restart ssh
