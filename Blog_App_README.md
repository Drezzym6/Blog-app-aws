# Blog Page Application — Django on AWS

> **Production-grade Django blog deployed across 13+ AWS services.** Custom VPC, CloudFront CDN, Route 53 failover, ALB with Auto Scaling, RDS MySQL 8.4, S3 media storage, Lambda event processing, DynamoDB indexing, and SSM secrets management. Deployed and tested on live AWS infrastructure.

---

## Table of Contents

- [Expected Outcome](#expected-outcome)
- [Overview](#overview)
- [Architecture Diagram](#architecture-diagram)
- [AWS Services Used](#aws-services-used)
- [Key Design Decisions](#key-design-decisions)
- [Tech Stack](#tech-stack)
- [Deployment Steps](#deployment-steps)
- [SSM Parameter Store](#ssm-parameter-store)
- [Issues Resolved During Deployment](#issues-resolved-during-deployment)
- [Production Improvements Identified](#production-improvements-identified)

---

## Expected Outcome

The screenshot below shows the live Blog Page Application after successful deployment. Users can register, log in, write posts, and upload images — all served through CloudFront over HTTPS, with data persisted in RDS MySQL 8.4 and media indexed in DynamoDB via Lambda.

![alt text](outcome.png)

*Live deployment — Clarusway Blog running on EC2 Auto Scaling Group behind CloudFront and ALB. Image uploaded to S3, Lambda triggered, DynamoDB record written.*

---

## Overview

This project deploys a full-stack Django blog application on a production-grade AWS architecture spanning two availability zones. The infrastructure is designed for high availability, security, and scalability — with zero plaintext credentials anywhere in the codebase.

**Every architectural decision was made to solve a specific problem — documented below.**

---

## Architecture Diagram

```
User Browser
     |
     | DNS Query
     v
Route 53 (Failover Routing)
     |-- Primary  --> CloudFront (CDN + HTTPS)
     |                    |
     |                    v
     |               ALB (Multi-AZ)
     |              /              \
     |    EC2 (Private AZ-A)   EC2 (Private AZ-B)
     |    Django + Gunicorn    Django + Gunicorn
     |              \              /
     |               RDS MySQL 8.4
     |               (Private Subnet)
     |
     |-- Secondary -> S3 Static Site (Maintenance Page)

S3 (Media Bucket)
     | S3 Event Trigger
     v
Lambda (Python 3.12)
     |
     v
DynamoDB (Media Index)

SSM Parameter Store --> EC2 User Data (fetches at boot --> /etc/blog.env chmod 600)
```

---

## AWS Services Used

| Service | Purpose | Notes |
|---|---|---|
| **VPC** | Isolated network | 10.90.0.0/16 · 2 public + 2 private subnets · 2 AZs |
| **EC2** | App servers | Ubuntu 24.04 · t2.micro · Private subnets |
| **ALB** | Load balancer | Internet-facing · Multi-AZ · HTTP→HTTPS redirect |
| **Auto Scaling Group** | Capacity | Desired 1 · Min 1 · Max 3 · CPU target 70% |
| **RDS MySQL 8.4** | Database | Private subnet · DB subnet group across both AZs |
| **S3** | Media storage | User uploads · VPC Gateway Endpoint |
| **S3** | Failover | Static maintenance page |
| **CloudFront** | CDN + HTTPS | ALB origin · HTTPS only |
| **Route 53** | DNS + failover | Health check on CloudFront · Primary/secondary |
| **Lambda** | Event processing | Python 3.12 · S3 trigger · Writes to DynamoDB |
| **DynamoDB** | Media index | Queried on page load |
| **SSM Parameter Store** | Secrets | 6 SecureString params · KMS encrypted |
| **ACM** | TLS certificates | CloudFront + ALB |
| **IAM** | Access control | EC2: S3 + SSM · Lambda: least privilege |
| **NAT Gateway** | Outbound | Private subnets |
| **SNS** | Notifications | ASG scaling events |

---

## Key Design Decisions

### 1. Custom VPC — Security Group Chaining
Private subnets for EC2 and RDS. Traffic can only enter through the ALB.
- ALB SG: HTTP/HTTPS from 0.0.0.0/0
- EC2 SG: HTTP from ALB SG only
- RDS SG: MySQL 3306 from EC2 SG only

### 2. NAT Gateway over NAT Instance
Original spec used `amzn-ami-vpc-nat-hvm` — deprecated. Migrated to managed NAT Gateway. Verified by running `curl www.google.com` from private EC2.

### 3. SSM Parameter Store — Zero Plaintext Credentials
All secrets fetched at boot into `/etc/blog.env` (chmod 600). Read by systemd. Never in source code, user data, or config files.

### 4. Gunicorn + systemd over Django runserver
`runserver` blocks the user data script — instance never signals completion to ASG and health checks never pass. It is also single-threaded. Gunicorn (3 workers) under systemd keeps the process alive across crashes and reboots.

### 5. VPC Gateway Endpoint for S3
EC2-to-S3 traffic stays on AWS private backbone. No NAT charges, no public internet exposure.

### 6. Lambda + DynamoDB for Media Indexing
S3 ListObjects on every page load is slow and expensive. Lambda writes to DynamoDB on each upload event. App queries DynamoDB — millisecond index lookups.

### 7. Route 53 Failover
Health check on CloudFront. Primary = CloudFront alias. On failure → auto-switches to static S3 maintenance page. Zero manual intervention.

---

## Tech Stack

| Category | Technology |
|---|---|
| **Application** | Python 3.12 · Django · mysqlclient · Gunicorn |
| **WSGI Server** | Gunicorn (3 workers · systemd managed) |
| **Compute** | EC2 Ubuntu 24.04 · Auto Scaling · Launch Templates |
| **Database** | RDS MySQL 8.4 |
| **Serverless** | Lambda Python 3.12 · DynamoDB |
| **CDN / DNS** | CloudFront · Route 53 · ACM |
| **Secrets** | SSM Parameter Store (SecureString / KMS) |
| **IaC** | Terraform (production improvement) |

---

## Deployment Steps

```bash
# 1. VPC + networking
#    - CIDR 10.90.0.0/16
#    - Public subnets: 10.90.10.0/24, 10.90.20.0/24
#    - Private subnets: 10.90.11.0/24, 10.90.21.0/24
#    - Internet Gateway, NAT Gateways, route tables
#    - VPC Gateway Endpoint for S3

# 2. Security groups (chained)
#    ALB SG  -> EC2 SG -> RDS SG -> Bastion SG

# 3. Store secrets in SSM Parameter Store

# 4. RDS MySQL 8.4 in private subnet

# 5. S3 buckets (media + failover static site)

# 6. ACM certificate (DNS validation, wait for ACTIVE)

# 7. IAM role for EC2 (S3FullAccess + SSMFullAccess)

# 8. Launch Template with user data script (see below)

# 9. ALB + Target Group (HTTPS 443, HTTP->443 redirect)

# 10. Auto Scaling Group (private subnets, both AZs)

# 11. CloudFront distribution (ALB origin, HTTPS only)

# 12. DynamoDB table (primary key: id)

# 13. Lambda function (Python 3.12, S3 trigger, 30s timeout)

# 14. Route 53 failover routing
```

### Launch Template User Data

```bash
#!/bin/bash

apt-get update -y
apt-get upgrade -y

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

ssm() { aws --region=us-east-1 ssm get-parameter --name "$1" --with-decryption --query 'Parameter.Value' --output text; }

SSM_PREFIX="/andre/capstone"

TOKEN=$(ssm "$SSM_PREFIX/token")

cd /home/ubuntu/ || exit 1
git clone https://"$TOKEN"@github.com/Drezzym6/Blog-app-aws.git

cd /home/ubuntu/Blog-app-aws || exit 1
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt

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

cd /home/ubuntu/Blog-app-aws/src || exit 1
# shellcheck disable=SC1091
set -a; source /etc/blog.env; set +a
/home/ubuntu/Blog-app-aws/venv/bin/python manage.py collectstatic --noinput
/home/ubuntu/Blog-app-aws/venv/bin/python manage.py migrate

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
```

---

## SSM Parameter Store

All parameters are **SecureString** (KMS encrypted). Fetched at boot into `/etc/blog.env` (chmod 600).

| Parameter | Type | Description |
|---|---|---|
| `/<prefix>/capstone/password` | SecureString | RDS MySQL password |
| `/<prefix>/capstone/username` | SecureString | RDS MySQL username |
| `/<prefix>/capstone/token` | SecureString | GitHub PAT |
| `/<prefix>/capstone/secret_key` | SecureString | Django SECRET_KEY |
| `/<prefix>/capstone/db_host` | SecureString | RDS endpoint |
| `/<prefix>/capstone/s3_bucket` | String | S3 media bucket name |

```bash
aws ssm put-parameter --name "/yourname/capstone/password"   --value "YOUR_DB_PASSWORD"   --type "SecureString"
aws ssm put-parameter --name "/yourname/capstone/username"   --value "YOUR_DB_USERNAME"   --type "SecureString"
aws ssm put-parameter --name "/yourname/capstone/token"      --value "YOUR_GITHUB_TOKEN"  --type "SecureString"
aws ssm put-parameter --name "/yourname/capstone/secret_key" --value "YOUR_SECRET_KEY"    --type "SecureString"
aws ssm put-parameter --name "/yourname/capstone/db_host"    --value "your-rds.rds.amazonaws.com" --type "SecureString"
aws ssm put-parameter --name "/yourname/capstone/s3_bucket"  --value "your-bucket-name"   --type "String"
```

---

## Issues Resolved During Deployment

| # | Problem | Root Cause | Fix |
|---|---|---|---|
| 1 | NAT instance unavailable | `amzn-ami-vpc-nat-hvm` deprecated | Migrated to managed NAT Gateway |
| 2 | SSH timeout on bastion | Stale /32 IP in SG inbound rule | Updated to current IP |
| 3 | Permission denied on private EC2 | SSH agent not forwarded | Used `ssh -A` from bastion |
| 4 | Python dependency conflicts | Global pip blocked (PEP 668) | Used virtualenv isolation |
| 5 | boto3 not finding credentials | Stale `AWS_ACCESS_KEY_ID` env var intercepting instance profile | Removed stale env var |
| 6 | MySQL connector compile failure | AMI missing `libmysqlclient-dev` and `python3-dev` | Switched AMI + explicit install in user data |

---

## Production Improvements Identified

| Improvement | Reason |
|---|---|
| **Terraform IaC** | Full reproducibility, one-command deploy/destroy |
| **Session Manager** | Eliminate bastion + port 22 + SSH key management |
| **RDS Multi-AZ** | Auto-failover under 2 min, zero data loss |
| **CloudFront cache invalidation** | Prevent stale content after edits |
| **Separate Django migrations** | Avoid race conditions on multi-instance launches |
| **AWS WAF** | SQL injection, XSS, DDoS filtering at edge |
| **CloudTrail** | Full API audit log |

---

## Author

**Andre Diya** — Junior Cloud & DevOps Engineer · Atlanta, GA
AWS Certified Solutions Architect Associate · AWS Certified Cloud Practitioner

- LinkedIn: [linkedin.com/in/andre-diya](https://linkedin.com/in/andre-diya)
- GitHub: [github.com/Drezzym6](https://github.com/Drezzym6)
- Email: andrediya01@gmail.com
