# Quick Start Guide - Langfuse V3 SAM Deployment

## Prerequisites Check

```bash
# Verify AWS CLI
aws --version

# Verify SAM CLI
sam --version

# Verify Docker
docker --version

# Configure AWS credentials if needed
aws configure
```

## Step-by-Step Deployment

### Step 1: Generate Secrets

```bash
# Generate all required secrets
make generate-secrets
```

Copy the generated values - you'll need them in the next step.

### Step 2: Update Parameters

Edit `parameters.json` and replace these placeholder values with your generated secrets:

```json
{
  "ParameterKey": "LangfuseWebNextAuthSecret",
  "ParameterValue": "YOUR_GENERATED_SECRET_HERE"
},
{
  "ParameterKey": "LangfuseWebSalt",
  "ParameterValue": "YOUR_GENERATED_SALT_HERE"
},
{
  "ParameterKey": "LangfuseWebEncryptionKey",
  "ParameterValue": "YOUR_GENERATED_KEY_HERE"
},
{
  "ParameterKey": "LangfuseWorkerSalt",
  "ParameterValue": "YOUR_GENERATED_SALT_HERE"
},
{
  "ParameterKey": "LangfuseWorkerEncryptionKey",
  "ParameterValue": "YOUR_GENERATED_KEY_HERE"
}
```

### Step 3: Build and Push Docker Images

```bash
# This will:
# - Create ECR repositories
# - Pull official Langfuse images
# - Build for linux/amd64 (Fargate compatible)
# - Push to your ECR
# - Update parameters.json with ECR URIs

make build-and-push
```

**Expected output:**
```
✓ All ECR repositories are ready
✓ Langfuse Web image pushed
✓ Langfuse Worker image pushed
✓ Clickhouse image pushed
```

**Time**: ~5-10 minutes (depending on your internet connection)

### Step 4: Deploy Infrastructure

```bash
make deploy
```

**Expected output:**
```
✓ Template is valid
✓ Deployment complete!
```

**Time**: ~25-35 minutes

The deployment creates:
- VPC with 3 AZs
- Aurora PostgreSQL cluster
- ElastiCache Valkey
- ECS Fargate services
- Application Load Balancer
- S3 buckets
- EFS for Clickhouse

### Step 5: Access Langfuse

```bash
# Get the URL
make get-alb-url

# Or open directly in browser
make open-langfuse
```

## What Gets Created?

| Resource | Configuration | Purpose |
|----------|---------------|---------|
| **VPC** | 3 AZs, public + private subnets | Network isolation |
| **Aurora PostgreSQL** | r6g.large x2 (writer+reader) | Primary database |
| **ElastiCache Valkey** | cache.t3.small x1 | Cache and queue |
| **ECS Clickhouse** | 1 vCPU, 8GB RAM | Analytics datawarehouse |
| **ECS Worker** | 2 vCPU, 4GB RAM | Background processing |
| **ECS Web** | 2 vCPU, 4GB RAM | Web UI and API |
| **ALB** | Application Load Balancer | Public access |
| **S3** | 2 buckets (blob + event) | File storage |
| **EFS** | General Purpose | Clickhouse persistence |

## Post-Deployment

### Create Your First User

1. Open the Langfuse URL in your browser
2. Click "Sign Up"
3. Enter your email and password
4. Create your first project

### View Logs

```bash
# Web service logs
make tail-web-logs

# Worker service logs
make tail-worker-logs

# Clickhouse logs
make tail-clickhouse-logs
```

### Check Stack Status

```bash
make status
```

## Cost

**Estimated**: ~$520/month

Primary cost drivers: Aurora PostgreSQL (r6g.large x2), NAT Gateways (3 AZs), ECS Fargate tasks, ElastiCache, ALB.

## Cleanup

To delete everything:

```bash
make destroy
```

**Warning**: This will delete:
- All infrastructure
- All data in Aurora PostgreSQL
- All data in Clickhouse
- All files in S3 buckets

## Next Steps

- Configure custom domain with Route 53 and ACM certificate
- Set up CloudWatch alarms
- Configure AWS Backup for EFS and Aurora
- Review IAM roles for least privilege
- Enable AWS WAF for ALB

## Getting Help

- **Langfuse Docs**: https://langfuse.com/docs
- **AWS SAM Docs**: https://docs.aws.amazon.com/serverless-application-model/
- **GitHub Issues**: Create an issue in your repository
