# Langfuse V3 on AWS ECS Fargate - CloudFormation Deployment

Deploy Langfuse V3 on AWS using CloudFormation/SAM with automated Docker image builds.

## Architecture

- **VPC**: 3 AZs with public/private subnets
- **ALB**: HTTPS with automatic HTTP→HTTPS redirect
- **Aurora PostgreSQL 15.4**: r6g.large (writer + reader)
- **ElastiCache Valkey 7.2**: Redis-compatible cache
- **ECS Fargate**: Clickhouse, Worker, Web services
- **EFS**: Persistent storage for Clickhouse
- **S3**: Blob and event storage

## Prerequisites

### Before You Begin

Create these resources in AWS Console:

1. **ACM Certificate** (AWS Certificate Manager)

   - Region: Same as deployment region
   - Domain: Your custom domain (e.g., `langfuse.example.com`)
   - Validation: DNS or Email
   - Copy the ARN (e.g., `arn:aws:acm:eu-west-1:123456:certificate/abc-123`)

2. **Route53 Hosted Zone**
   - Domain: Your domain
   - Copy the Hosted Zone ID (e.g., `Z0123456789ABCDEFGHIJ`)

### Required Tools

Install these on your machine:

```bash
# AWS CLI
aws --version  # Requires v2.x+

# SAM CLI
sam --version  # Requires v1.100+

# Docker
docker --version

# jq (for JSON processing)
brew install jq  # macOS
apt install jq   # Linux
```

### AWS Credentials

```bash
aws configure
# Ensure you have permissions for: EC2, VPC, ECS, ECR, RDS, ElastiCache, S3, EFS, CloudFormation, IAM, Secrets Manager, Route53, ACM
```

## Deployment Steps

### 1. Generate Secrets

Generate required encryption keys:

```bash
# Generate all secrets
make generate-secrets
```

This outputs:

```
NEXTAUTH_SECRET=xyz123...
WEB_SALT=abc456...
WEB_ENCRYPTION_KEY=def789...
WORKER_SALT=ghi012...
WORKER_ENCRYPTION_KEY=jkl345...
```

**Save these values** - you'll need them in the next step.

### 2. Configure Parameters

Edit `parameters.json` with your values:

```json
{
  "ParameterKey": "LangfuseWebNextAuthSecret",
  "ParameterValue": "YOUR_GENERATED_NEXTAUTH_SECRET"
},
{
  "ParameterKey": "LangfuseWebSalt",
  "ParameterValue": "YOUR_GENERATED_WEB_SALT"
},
{
  "ParameterKey": "LangfuseWebEncryptionKey",
  "ParameterValue": "YOUR_GENERATED_WEB_ENCRYPTION_KEY"
},
{
  "ParameterKey": "LangfuseWorkerSalt",
  "ParameterValue": "YOUR_GENERATED_WORKER_SALT"
},
{
  "ParameterKey": "LangfuseWorkerEncryptionKey",
  "ParameterValue": "YOUR_GENERATED_WORKER_ENCRYPTION_KEY"
},
{
  "ParameterKey": "CertificateArn",
  "ParameterValue": "arn:aws:acm:eu-west-1:123456:certificate/YOUR-CERT-ID"
},
{
  "ParameterKey": "DomainName",
  "ParameterValue": "langfuse.example.com"
},
{
  "ParameterKey": "HostedZoneId",
  "ParameterValue": "Z0123456789ABCDEFGHIJ"
}
```

See `parameters.example.json` for a complete template.

### 3. Build and Push Docker Images

Build images for Fargate (linux/amd64) and push to ECR:

```bash
make build-and-push
```

This will:

- Create ECR repositories
- Pull official Langfuse images
- Build for linux/amd64 (Mac users: automatically handled)
- Push to your ECR
- Update `parameters.json` with image URIs

**Time**: ~10-15 minutes

### 4. Deploy Infrastructure

```bash
make deploy
```

CloudFormation will create all resources. **Time**: ~25-35 minutes

### 5. Access Langfuse

After deployment completes:

```bash
# Get your URL
make get-alb-url

# Or open directly
make open-langfuse
```

Access at `https://langfuse.example.com` and create your admin account.

## Architecture Details

### Clickhouse Deployment

Clickhouse is configured for single-instance deployment with EFS persistence. Key configuration details:

**Deployment Strategy:**

- Deployed to a single subnet (AZ) to prevent file locking conflicts
- AZ Rebalancing disabled to ensure predictable deployment behavior
- Sequential deployment (stops old task before starting new)

**Why this configuration?**
Clickhouse requires exclusive access to its data directory on EFS. Running multiple instances simultaneously causes `exit code 76` (CANNOT_OPEN_FILE) errors due to file locking. The configuration ensures:

```yaml
AvailabilityZoneRebalancing: DISABLED # Prevents multi-AZ task launches
MinimumHealthyPercent: 0 # Allows full stop of old task
MaximumPercent: 100 # Prevents overlapping deployments
DeploymentCircuitBreaker: # Auto-rollback on failure
  Enable: true
  Rollback: true
```

**Trade-offs:**

- Single AZ deployment (no AZ redundancy for the task)
- EFS data remains replicated across AZs for durability
- Downtime during deployments (~2 minutes during health check)

## Configuration

### Infrastructure Sizing

Edit in `parameters.json`:

```json
{
  "ParameterKey": "DbInstanceClass",
  "ParameterValue": "db.r6g.large"  // Aurora instance size
},
{
  "ParameterKey": "LangfuseWorkerDesiredCount",
  "ParameterValue": "1"  // Worker count
}
```

### Feature Flags

**Disable Public Signups:**

Set to `true` to disable public signups (default), or `false` to allow anyone to create accounts:

```json
{
  "ParameterKey": "LangfuseWebAuthDisableSignup",
  "ParameterValue": "true" // true = disabled, false = enabled
}
```

After changing, redeploy:

```bash
make deploy
```

## Makefile Commands

### Deployment

- `make build-and-push` - Build and push Docker images
- `make deploy` - Deploy infrastructure
- `make deploy-all` - Build + push + deploy
- `make validate` - Validate template

### Operations

- `make status` - Show stack status
- `make get-alb-url` - Get ALB URL
- `make open-langfuse` - Open in browser
- `make logs` - Interactive log viewer
- `make tail-web-logs` - Tail web logs
- `make destroy` - Delete entire stack

## Updating

### Update Images

This pulls the latest version of Langfuse and Clickhouse. Update the

```bash
make build-and-push
make deploy
```

### Update Configuration

1. Edit `parameters.json`
2. Run `make deploy`

### Update Infrastructure

1. Edit `template.yaml`
2. Run `make validate`
3. Run `make deploy`

## Troubleshooting

### ECR Authentication Fails

```bash
make ecr-login
```

### Deployment Fails

Check CloudFormation events:

```bash
aws cloudformation describe-stack-events \
  --stack-name langfuse-v3 \
  --max-items 20
```

### Clickhouse Service Fails to Deploy (Exit Code 76)

**Symptom:** Clickhouse ECS tasks repeatedly fail with exit code 76 (CANNOT_OPEN_FILE).

**Cause:** Multiple Clickhouse tasks attempting to access the same EFS data directory simultaneously.

**Solution:** The template is pre-configured to prevent this. If you encounter this:

1. Check if multiple deployments are running:

```bash
aws ecs describe-services \
  --cluster langfuse \
  --services clickhouse \
  --query 'services[0].deployments'
```

2. If stuck in UPDATE_ROLLBACK_FAILED:

```bash
aws cloudformation continue-update-rollback \
  --stack-name langfuse-v3 \
  --region eu-west-1
```

3. Redeploy after rollback completes:

```bash
make deploy
```

### Application Not Accessible

Check ECS service:

```bash
aws ecs describe-services \
  --cluster langfuse \
  --services langfuse_web
```

Check logs:

```bash
make tail-web-logs
make tail-worker-logs
make tail-clickhouse-logs
```

### Database Connection Issues

The Aurora cluster takes time to provision. Check:

```bash
aws rds describe-db-clusters \
  --db-cluster-identifier langfuse-db \
  --query 'DBClusters[0].Status'
```

## Cost Estimate

Approximate monthly costs (us-east-1, on-demand):

| Service           | Config       | Monthly      |
| ----------------- | ------------ | ------------ |
| Aurora PostgreSQL | r6g.large x2 | ~$280        |
| ElastiCache       | t3.small     | ~$25         |
| ECS Fargate       | 3 tasks      | ~$90         |
| NAT Gateway       | 3 AZs        | ~$100        |
| ALB               | Standard     | ~$20         |
| EFS               | ~10 GB       | ~$3          |
| **Total**         |              | **~$518/mo** |

## Security

### Encrypted Traffic

- All traffic uses HTTPS
- HTTP automatically redirects to HTTPS
- TLS certificate from ACM

### Encrypted Data

- Aurora: Encrypted at rest
- EFS: Encrypted at rest and in transit
- S3: Block public access enabled
- Secrets Manager: Database credentials

### Network

- ECS tasks in private subnets
- Security groups with least privilege
- VPC endpoints for S3

## Backup

### Automated

- Aurora: 3-day retention
- ElastiCache: 3-day snapshots
