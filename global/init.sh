#!/bin/bash
# Init script to install required dependencies on all images

echo "Updating package manager..."
sudo yum update
echo "Done."

echo "Installing dependencies..."
sudo yum install -y python27-pip awslogs
echo "Done."

# Always use UTC for logs !
echo "Setting local time to UTC..."
sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime
echo "Done."
