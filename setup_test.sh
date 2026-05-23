#!/bin/bash
# ============================================================
# Step-by-step setup script — run each STEP manually over SSH
# as root (sudo -i) so you can verify each stage before moving on.
# ============================================================

# ── STEP 1: System packages ─────────────────────────────────
# Run this first and confirm it exits with no errors.
apt-get update -y && apt-get upgrade -y
apt-get install -y git \
    python3 \
    python3-pip \
    python3-venv \
    python3.12-venv \
    python3-dev \
    default-libmysqlclient-dev \
    pkg-config \
    unzip \
    curl

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

echo "✓ STEP 1 done — packages installed"

# ── STEP 2: Verify SSM access ────────────────────────────────
# If any of these print "None" or an error, your IAM role is
# missing ssm:GetParameter or the parameter path is wrong.
SSM_PREFIX="/andre/capstone"
ssm() { aws --region=us-east-1 ssm get-parameter --name "$1" --with-decryption --query 'Parameter.Value' --output text; }

echo "TOKEN    : $(ssm "$SSM_PREFIX/token")"
echo "DB_HOST  : $(ssm "$SSM_PREFIX/db_host")"
echo "DB_USER  : $(ssm "$SSM_PREFIX/username")"
echo "DB_PASS  : $(ssm "$SSM_PREFIX/password" | head -c 4)****"
echo "S3_BUCKET: $(ssm "$SSM_PREFIX/s3_bucket")"
echo "SECRET_KEY: $(ssm "$SSM_PREFIX/secret_key" | head -c 6)****"

echo "✓ STEP 2 done — SSM parameters readable"

# ── STEP 3: Clone repo ───────────────────────────────────────
SSM_PREFIX="/andre/capstone"
ssm() { aws --region=us-east-1 ssm get-parameter --name "$1" --with-decryption --query 'Parameter.Value' --output text; }
TOKEN=$(ssm "$SSM_PREFIX/token")
cd /home/ubuntu/ || exit 1
git clone https://"$TOKEN"@github.com/Drezzym6/Blog-app-aws.git

ls /home/ubuntu/Blog-app-aws   # should list your project files
echo "✓ STEP 3 done — repo cloned"

# ── STEP 4: Python venv + dependencies ──────────────────────
cd /home/ubuntu/Blog-app-aws || exit 1
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

python -c "import django; print('Django', django.__version__)"
python -c "import gunicorn; print('gunicorn ok')"
python -c "import MySQLdb; print('mysqlclient ok')"
python -c "import storages; print('django-storages ok')"
echo "✓ STEP 4 done — dependencies installed"

# ── STEP 5: Write env file ───────────────────────────────────
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

cat /etc/blog.env   # verify values look correct (SECRET_KEY will be long random string)
echo "✓ STEP 5 done — /etc/blog.env written"

# ── STEP 6: Database connectivity ───────────────────────────
# This checks that the EC2 security group can reach RDS on port 3306.
source /etc/blog.env
python3 -c "
import MySQLdb
try:
    conn = MySQLdb.connect(host='${DB_HOST}', user='${DB_USERNAME}', passwd='${DB_PASSWORD}', db='andreblog')
    print('✓ DB connection OK')
    conn.close()
except Exception as e:
    print('✗ DB connection FAILED:', e)
"
echo "✓ STEP 6 done — RDS reachable"

# ── STEP 7: collectstatic (writes to S3) ────────────────────
cd /home/ubuntu/Blog-app-aws/src || exit 1
set -a; source /etc/blog.env; set +a
source /home/ubuntu/Blog-app-aws/venv/bin/activate

python manage.py collectstatic --noinput
# Should print "X files copied to S3" — if you see S3 errors,
# check the IAM role has s3:PutObject on your bucket.
echo "✓ STEP 7 done — static files on S3"

# ── STEP 8: Migrations ───────────────────────────────────────
python manage.py migrate
echo "✓ STEP 8 done — DB migrations applied"

# ── STEP 9: Quick Django check ───────────────────────────────
python manage.py check --deploy 2>&1 | grep -E "WARNINGS|ERRORS|System check"
echo "✓ STEP 9 done — Django system check passed"

# ── STEP 10: Install & start systemd service ─────────────────
cat > /etc/systemd/system/blog.service << 'EOF'
[Unit]
Description=Django Blog Application
After=network.target

[Service]
User=root
WorkingDirectory=/home/ubuntu/Blog-app-aws/src
EnvironmentFile=/etc/blog.env
Environment="PATH=/home/ubuntu/Blog-app-aws/venv/bin"
ExecStart=/home/ubuntu/Blog-app-aws/venv/bin/gunicorn \
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

# Wait a moment then check status
sleep 3
systemctl status blog --no-pager

echo "✓ STEP 10 done — gunicorn service running"

# ── STEP 11: Smoke test ──────────────────────────────────────
# Hit the app locally — should return HTTP 200 or 301/302 (redirect to login).
curl -o /dev/null -sw "Local HTTP status: %{http_code}\n" http://localhost:80/

# Check gunicorn logs if something looks wrong:
# tail -50 /var/log/gunicorn-error.log
# tail -50 /var/log/gunicorn-access.log
# journalctl -u blog -n 50 --no-pager

echo "✓ STEP 11 done — app responding on port 80"
echo ""
echo "All steps complete. Hit the ALB DNS or www.andrediya.com to verify end-to-end."
