#!/bin/bash
apt-get update -y
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Map host port 443 to container port 80
docker run -d -p 443:80 aivisp/slice.sip.app.v1.0
