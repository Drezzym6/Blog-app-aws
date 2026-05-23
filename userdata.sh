#!/bin/bash

apt-get update -y
apt-get upgrade -y

# Ubuntu 24.04 ships Python 3.12; python3.10-dev no longer exists.
# pkg-config is required by mysqlclient's build step.
# python3-venv is needed to create isolated environments (PEP 668 blocks
# global pip installs on 24.04).
apt-get install -y git \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    default-libmysqlclient-dev \
    pkg-config \
    awscli

# Helper: fetch a SecureString or String from SSM Parameter Store
ssm() { aws --region=us-east-1 ssm get-parameter --name "$1" --with-decryption --query 'Parameter.Value' --output text; }

# Replace "yourname" below with your own SSM path prefix
SSM_PREFIX="/andre/capstone"

TOKEN=$(ssm "$SSM_PREFIX/token")

cd /home/ubuntu/ || exit 1
# Replace "your-github-username" with your actual GitHub username
git clone https://"$TOKEN"@github.com/your-github-username/andre-caps-aws.git

cd /home/ubuntu/andre-caps-aws || exit 1
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt

# Fetch application secrets from SSM and write to a protected environment file.
# The systemd service reads this file so secrets are never embedded in code or
# the service unit itself.
SECRET_KEY=$(ssm "$SSM_PREFIX/secret_key")
DB_HOST=$(ssm "$SSM_PREFIX/db_host")
DB_USERNAME=$(ssm "$SSM_PREFIX/username")
DB_PASSWORD=$(ssm "$SSM_PREFIX/password")
AWS_BUCKET=$(ssm "$SSM_PREFIX/s3_bucket")

cat > /etc/blog.env << EOF
SECRET_KEY=${SECRET_KEY}
DEBUG=False
DB_NAME=andreblog
DB_HOST=${DB_HOST}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
AWS_STORAGE_BUCKET_NAME=${AWS_BUCKET}
AWS_S3_REGION_NAME=us-east-1
EOF
chmod 600 /etc/blog.env

cd /home/ubuntu/andre-caps-aws/src || exit 1
python3 manage.py collectstatic --noinput
python3 manage.py migrate

# Run gunicorn as a systemd service instead of runserver:
#   - runserver blocks the userdata script so the instance never signals
#     "complete" to the ASG and health checks never pass.
#   - runserver is single-threaded and not safe for production traffic.
#   - systemd keeps the process alive across crashes and reboots.
cat > /etc/systemd/system/blog.service << 'EOF'
[Unit]
Description=Django Blog Application
After=network.target

[Service]
User=root
WorkingDirectory=/home/ubuntu/andre-caps-aws/src
EnvironmentFile=/etc/blog.env
Environment="PATH=/home/ubuntu/andre-caps-aws/venv/bin"
ExecStart=/home/ubuntu/andre-caps-aws/venv/bin/gunicorn \
    --workers 3 \
    --bind 0.0.0.0:80 \
    --timeout 120 \
    --access-logfile /var/log/gunicorn-access.log \
    --error-logfile /var/log/gunicorn-error.log \
    cblog.wsgi:application
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable blog
systemctl start blog
