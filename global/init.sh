#!/bin/bash
# Init script to install required dependencies on all images

sudo yum update
sudo yum install -y python34-pip awslogs

# Always use UTC for logs !
sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime
