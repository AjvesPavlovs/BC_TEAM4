#!/bin/bash
apt-get update -y
apt-get install -y docker.io nginx curl jq amazon-cloudwatch-agent
systemctl start docker
systemctl enable docker

# Set up Nginx dynamic include structure
mkdir -p /etc/nginx/conf.d
echo "set \$active_port 8081;" > /etc/nginx/conf.d/active_port.conf

# Set up CloudWatch Agent configuration for Memory and Disk metrics
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat << 'EOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "aggregation_dimensions": [
      ["InstanceId"]
    ],
    "metrics_collected": {
      "mem": {
        "measurement": [
          "mem_used_percent"
        ]
      },
      "disk": {
        "measurement": [
          "disk_used_percent"
        ],
        "resources": [
          "/"
        ]
      }
    }
  }
}
EOF

# Start and enable CloudWatch Agent with the custom config
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Pull and start initial blue container
docker pull aivisp/slice.sip.app.v1.0:latest
docker run -d --name slice-blue --restart unless-stopped -p 8081:80 aivisp/slice.sip.app.v1.0:latest

# Restart Nginx to load configuration
systemctl restart nginx
systemctl enable nginx