#!/bin/bash
apt-get update -y
apt-get install -y docker.io git curl

# Start and enable Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

# Ensure snap/SSM agent is active (Ubuntu 22.04 includes snap, SSM agent can also be installed via snap if needed)
systemctl enable snapd
