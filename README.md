# Database Statistics, Configuration, Performance Metrics Collection Guide

> **Disclaimer**: This tool collects database metrics and configuration data from your AWS environment for Well-Architected review purposes. Review the README.MD carefully and test against your staging/QA environment first to understand the scipts and data collected. Review the data collected before sharing and ensure it complies with your organization's data sharing policies. Please issue a support case to share any data collected to AWS. If any concerns, please reach back to your account SA and proceed with ad-hoc data collection using the issued support case.

![DB Metrics Report Demo](demo/demo-metrics.gif)

## What this does

Deploys a lightweight EC2 instance in your AWS account that:

- Discovers all PostgreSQL databases (Aurora PostgreSQL, RDS for PostgreSQL, and RDS Multi-AZ DB Clusters for PostgreSQL) in your account/region
- Collects [CloudWatch metrics](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.AuroraMonitoring.Metrics.html), [Performance Insights](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_DatabaseInsights.html) data, and database configuration
- Collects deeper database statistics — query performance (`pg_stat_statements`), table/index bloat, health insights, and workload trends via [PGPerfStatsSnapper](https://github.com/aws-samples/aurora-and-database-migration-labs/tree/master/Code/PGPerfStatsSnapper) (requires [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html) to access DB from your account)
- Generates interactive HTML reports for visual exploration of collected metrics
- Uploads collected data to an S3 bucket in your account for review

## Prerequisites

- AWS CLI configured with your account credentials
- A VPC with a subnet (public or private — see deployment options below)
- IAM permissions: EC2, CloudFormation, S3, RDS, CloudWatch, Performance Insights
- An EC2 Key Pair — required only for **public subnet** deployments (SSH access). Not needed for `--no-public-ip` deployments.

### Network ACL (NACL) requirements

If the subnet you deploy into has a custom [Network ACL](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html) (non-default), verify the following rules are present **before deploying**. Unlike Security Groups, NACLs are stateless — return traffic must be explicitly allowed.

**Outbound NACL rules required:**

| Port | Protocol | Destination | Purpose |
|------|----------|-------------|---------|
| 443 | TCP | 0.0.0.0/0 | HTTPS — AWS APIs, S3, GitHub, package repos, CloudWatch agent |
| 5432 (or `--db-port` value) | TCP | RDS/Aurora CIDR or 0.0.0.0/0 | PostgreSQL — invasive collection only |
| 1024–65535 | TCP | 0.0.0.0/0 | Ephemeral ports — return traffic for all outbound connections |

**Inbound NACL rules required:**

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | Your IP/32 | SSH access (public subnet only) |
| 1024–65535 | TCP | 0.0.0.0/0 | Ephemeral ports — return traffic for outbound HTTPS and PostgreSQL connections |

> **Note**: The default VPC NACL allows all traffic in both directions — no changes needed if you are using the default NACL. Custom NACLs that deny ephemeral port return traffic are the most common cause of silent connectivity failures (instance appears to deploy successfully but `dnf`, `git clone`, and AWS API calls hang or time out).

## Step 1: Deploy the data collection instance

Clone the repository and run the deploy script:

```bash
git clone https://github.com/aws-samples/sample-rds-aurora-postgresql-stats-collection.git
cd sample-rds-aurora-postgresql-stats-collection

# Option 1: Public subnet (SSH access)
bash deployment/deploy-db-stats-collection.sh \
  --key-pair <your-key-pair-name> \
  --vpc-id <your-vpc-id> \
  --subnet-id <your-public-subnet-id> \
  --allowed-cidr <your-ip>/32 \
  --region <your-region>
  --db-port 5432          # optional: only needed if your RDS/Aurora endpoint uses a non-standard port

# Option 2: Private subnet with NAT Gateway (SSM access, no SSH)
bash deployment/deploy-db-stats-collection.sh \
  --no-public-ip \
  --vpc-id <your-vpc-id> \
  --subnet-id <your-private-subnet-id> \
  --region <your-region> \
  --db-port 5432          # optional: only needed if your RDS/Aurora endpoint uses a non-standard port

# Option 3: Private subnet with NAT Gateway — CFN creates SSM VPC endpoints to keep SSM traffic off the public internet
bash deployment/deploy-db-stats-collection.sh \
  --no-public-ip \
  --create-ssm-endpoints \
  --vpc-id <your-vpc-id> \
  --subnet-id <your-private-subnet-id> \
  --region <your-region> \
  --db-port 5432          # optional: only needed if your RDS/Aurora endpoint uses a non-standard port
```

The script will:

1. Package the repo contents and upload to S3 (fallback if the EC2 instance can't reach GitHub)
2. Deploy a CloudFormation stack (`wal-db-stats-collection`) with a `t3.medium` EC2 instance
3. The EC2 instance clones the repo from GitHub on boot (falls back to S3 if GitHub is unreachable)
4. Print the instance ID, IP, SSM connect command, and data S3 bucket name on completion

> **Note**: In a private subnet with a NAT Gateway, [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/what-is-systems-manager.html) works automatically via NAT — no VPC endpoints are required. It requires outbound connectivity to `ssm`, `ssmmessages`, and `ec2messages` endpoints for keeping SSM traffic off the public internet. If your VPC already has SSM VPC endpoints, the deploy script automatically adds the instance subnet and security group to them. Use `--create-ssm-endpoints` if you want SSM traffic to stay within the AWS network (off the public internet) — CloudFormation will create the three required Interface VPC Endpoints scoped to the deployment subnet.

Wait ~10 minutes for the instance to finish setup after the stack completes.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--key-pair` | Conditional | — | EC2 Key Pair name for SSH access. Required when deploying into a **public subnet**. Not required with `--no-public-ip`. |
| `--vpc-id` | Yes | — | VPC ID where the EC2 instance will be deployed. **Must be the same VPC as your RDS/Aurora cluster** so the instance can reach the database endpoint. |
| `--subnet-id` | Yes | — | Subnet ID within the VPC above. Two options: **(1) Public subnet** (with an Internet Gateway) — instance gets a public IP, SSH works directly from your machine. **(2) Private subnet with a [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)** — SSH is not possible without a bastion or VPN. Outbound traffic routes via NAT for S3 uploads and package installation. Use [AWS Systems Manager Session Manager](#accessing-the-instance-in-a-private-subnet) to connect. |
| `--allowed-cidr` | Conditional | — | CIDR allowed for SSH inbound on port 22. **Must be your specific IP** (e.g. `203.0.113.42/32`). `0.0.0.0/0` is rejected — open SSH access is a security risk. Find your IP with `curl -s ifconfig.me`. Required when using a public subnet. Not required with `--no-public-ip`. |
| `--no-public-ip` | No | — | Deploy without a public IP address. Use when deploying into a **private subnet with a NAT Gateway**. SSH is not available; connect via [AWS Systems Manager Session Manager](#accessing-the-instance-in-a-private-subnet). When set, `--key-pair` and `--allowed-cidr` are not required. The deploy script automatically configures pre-existing SSM VPC endpoints if present. |
| `--create-ssm-endpoints` | No | — | Use with `--no-public-ip` when the VPC has **no existing SSM VPC endpoints**. Creates three Interface VPC Endpoints (`ssm`, `ssmmessages`, `ec2messages`) as part of the CloudFormation stack, enabling Session Manager connectivity via VPC endpoints rather than via NAT. A NAT Gateway is still required for bootstrap and S3 uploads. See [SSM VPC endpoint options](#ssm-vpc-endpoint-options-for-no-public-ip-deployments) below. |
| `--db-port` | No | `5432` | PostgreSQL port on your RDS/Aurora endpoint. Only needed for invasive collection if your database uses a non-standard port. Drives the outbound security group egress rule. |
| `--region` | No | `us-east-1` | AWS region to deploy into |
| `--instance-type` | No | `t3.medium` | EC2 instance type |
| `--sa-data-bucket` | No | auto-created | Existing S3 bucket name for data sharing with your SA. If omitted, a bucket named `wal-db-stats-collection-<account-id>` is created automatically. |
| `--stack-name` | No | `wal-db-stats-collection` | CloudFormation stack name |
| `--enable-scheduled` | No | `true` | Run collection daily automatically |
| `--schedule` | No | `0 6 * * *` | Cron schedule (daily at 6 AM UTC) |

## Step 2: Access the instance for data collection

SSH to the instance and run the collection script:

```bash
ssh -i <your-key-pair>.pem ec2-user@<instance-ip>
```

### Accessing the instance in a private subnet

If you deploy into a private subnet (no public IP), SSH from your machine won't reach the instance. Use **AWS Systems Manager Session Manager** instead — no open inbound ports, no bastion host required.

> **Note**: The EC2 instance role already includes the `AmazonSSMManagedInstanceCore` policy, so SSM is enabled automatically.

**Connecting via Session Manager**

**AWS Console:**

1. Open the [EC2 console](https://console.aws.amazon.com/ec2/) → Instances
2. Select the instance → Connect → Session Manager → Connect

**AWS CLI:**
```bash
aws ssm start-session --target <instance-id> --region <your-region>
```

The deploy script prints the exact SSM command in the stack outputs after deployment.

## Step 3: Run database statistics and metrics collection 

Database statistics and metrics collection gathers CloudWatch metrics (7 days), Performance Insights, and RDS/Aurora configuration for all PostgreSQL databases discovered in your account. Additionally, it collects database statistics and query performance data using extension [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) and [PGPerfStatsSnapper](https://github.com/aws-samples/aurora-and-database-migration-labs/blob/master/Code/PGPerfStatsSnapper/README.md) for performance and workload analysis. This requires database credentials stored in AWS Secrets Manager.

> **Note**: Database statistics and metrics collection runs read-only queries against your database. No data is modified. Queries are lightweight and designed to have minimal performance impact. Test with your QA/test environment to understand the metrics collected before running against production. If you have concerns about direct database access, see [(Optional) Collect CloudWatch metrics only](#optional-collect-cloudwatch-metrics-only) — however, skipping in-depth database statistics and metrics collection limits the SA's ability to identify slow queries and top SQL by execution time (`pg_stat_statements`), table-level bloat and sequential scan patterns (`pg_stat_user_tables`), unused and redundant indexes (`pg_stat_user_indexes`), checkpoint and buffer write pressure (`pg_stat_bgwriter`), and historical workload trends from PGPerfStatsSnapper snapshots. These are the primary inputs for Well Architected Review tuning recommendations.

### Step 3.1 Enable database statistics collection

Run `enable-invasive-collection.sh` once per cluster. Each call registers that cluster for invasive collection — you can enable as many clusters as needed before running `collect-and-share.sh`.

```bash
cd /home/ec2-user/wal-db-stats-collection
./enable-invasive-collection.sh \
  <cluster-id> \
  <db-host> \
  <db-user> \
  <db-secret-arn> \
  [db-name] \
  [pgsnapper-min-days] \
  [pgsnapper-interval] \
  [skip-pg-stat-statements]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `cluster-id` | Yes | RDS cluster or instance identifier. For RDS Multi-AZ DB Clusters, use the cluster identifier (e.g. `my-maz-cluster`). |
| `db-host` | Yes | Database endpoint hostname. For Aurora and RDS Multi-AZ DB Clusters, use the **writer endpoint** to capture write workload, `pg_stat_statements`, and PGSnapper snapshots from the primary. For RDS Multi-AZ DB Clusters, this is the cluster-level writer endpoint. |
| `db-user` | Yes | Database username |
| `db-secret-arn` | Yes | Secrets Manager ARN containing the DB password |
| `db-name` | No | Database name to connect to (default: `postgres`) |
| `pgsnapper-min-days` | No | Minimum days of snapshots required (default: `1`; use `0.1` for ~2.4 hours) |
| `pgsnapper-interval` | No | Snapshot interval in minutes (default: `60`) |
| `skip-pg-stat-statements` | No | Set to `true` to skip the `pg_stat_statements` prerequisite check (default: `false`). Use when the extension is not installed on the cluster. |

> **Note**: If your `db-secret-arn` contains `!` (e.g. RDS managed secrets like `rds!cluster-...`), wrap it in **single quotes** to prevent bash history expansion.

Example:
```bash
./enable-invasive-collection.sh \
  my-aurora-cluster \
  my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com \
  postgres \
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!cluster-xxxxx' \
  my_db \
  1 \
  60 \
  false   # set to true if pg_stat_statements is not installed
```

With the example above (`pgsnapper-min-days=1`, `pgsnapper-interval=60`), wait at least 1 day between runs. For a quick test, use `pgsnapper-min-days=0.01` (~15 minutes) and `pgsnapper-interval=1` (1 minute interval).

### Step 3.2 Run collection and generate reports

Database statistics and metrics collection requires **two runs** of `./collect-and-share.sh`:

1. **Run 1 (setup only)** — installs the PGSnapper cron job and runs an initial snapshot to verify connectivity. **No data collection happens on this run** — no non-invasive metrics, no database statistics, no schema or query performance data. This keeps Run 1 fast and avoids collecting data that would be stale by Run 2.
2. **Wait** — allow snapshots to accumulate for at least `pgsnapper-min-days` worth of data.
3. **Run 2 (collect everything)** — collects **all** data with aligned timestamps: non-invasive metrics (CloudWatch, Performance Insights, configuration) for the entire fleet, plus invasive data (database statistics, schema, query performance, PGSnapper analysis) for flagged clusters. Because both non-invasive and invasive data are collected in the same run, all metrics share the same time window.

```bash
# Run 1 — setup only: installs cron, verifies connectivity (no data collection)
./collect-and-share.sh

# Wait for pgsnapper-min-days worth of snapshots...

# Run 2 — collects all data + generates interactive HTML reports
./collect-and-share.sh --generate-report --skip-security
```

> **Note**: If the initial snapshot fails during Run 1 (bad credentials, network issue, etc.), the cron job will **not** be installed. Fix the underlying issue and re-run `./collect-and-share.sh` — it will detect that setup is still needed and retry.

> **Note**: `--skip-security` excludes security-related queries (user roles, privileges, SSL, passwords, RLS, audit config) from the collection. Remove the flag if you want security data collected.

> **Note**: `--generate-report` produces a self-contained interactive HTML report for each database (7 tabs: Configuration, CloudWatch Metrics, Performance Insights, Security, Database Health, Workload Trends, Schema Explorer). Open the `*_report.html` file in any browser — no internet, server, or additional software required.

Collected data and reports are uploaded to S3:
```
s3://wal-db-stats-collection-<account-id>/db-stats/<timestamp>/
├── database-1_invasive_data.json           (raw data for SA)
├── database-1_invasive_report.html         (interactive visual report)
├── database-1_non_invasive_data.json
├── database-1_non_invasive_report.html
└── ...
```

### (Optional) Collect CloudWatch metrics only

If you have any concerns about running database statistics and metrics collection, you can run non-invasive collection only: CloudWatch metrics (7 days), Performance Insights, and RDS/Aurora configuration for all PostgreSQL databases discovered in your account.

If you previously ran `enable-invasive-collection.sh` for one or more clusters but have decided not to proceed with in-depth database statistics and metrics collection, remove the flag file(s) before running `collect-and-share.sh`. 

```bash
cd /home/ec2-user/wal-db-stats-collection

# Remove a specific cluster's flag
rm data/flags/<cluster-id>.flag

# Or remove all registered clusters at once
rm -f data/flags/*.flag

# Then run non-invasive collection only
./collect-and-share.sh
```

> **Note**: Removing the flag file only prevents invasive collection from running — it does not affect any PGSnapper cron job that may have already been installed. However, the cron job is **automatically removed** after a successful Run 2 collection. If you need to remove it manually before that:
> ```bash
> crontab -l | grep -v 'pg_perf_stat_snapper' | crontab -
> ```

## Step 4: Share collected data with your SA

Download the collected data from S3 and share it with your SA via a support case:

```bash
# Download the data package locally
aws s3 sync s3://wal-db-stats-collection-<account-id>/db-stats/ ./db-stats-export/

# Then attach the data to your support case or share via your preferred secure channel
```

Your SA will use this data to perform Well Architected Review and provide you with a comprehensive report.

## Data collected

**Non-invasive** (no DB credentials needed):
- RDS/Aurora cluster and instance configuration
- CloudWatch metrics (CPU, memory, IOPS, connections, replication lag — 7 days)
- Performance Insights top SQL and wait events
- Parameter group settings
- Subnet, VPC, and security group configuration

**Invasive** (requires DB credentials):
- All of the above, plus:
- `pg_stat_statements` — top queries by execution time and call count *(skipped if extension not installed; pass `skip-pg-stat-statements=true` to `enable-invasive-collection.sh`)*
- `pg_stat_user_tables` — table bloat, sequential scans, DML activity
- `pg_stat_user_indexes` — unused and duplicate indexes
- `pg_stat_bgwriter` — checkpoint and buffer statistics
- PostgreSQL health insights — comprehensive assessment across 9 areas: database overview, configuration health, connection activity, replication status, data footprint, query/IO performance, maintenance health, optimization opportunities, and security audit *(security queries can be excluded with `--skip-security`)*
- PGPerfStatsSnapper workload snapshots (historical query performance trends, session activity, CPU-heavy queries, checkpoint/temp file trends)

## Security and privacy

- Database credentials are retrieved from Secrets Manager — never stored in plaintext
- All data is encrypted in transit (HTTPS/TLS) and at rest (S3 SSE)
- The S3 bucket is private with public access blocked
- Data is automatically deleted from S3 after 30 days
- You retain full control of the S3 bucket — data stays in your account

### PII handling

PII redaction runs **automatically** before any data is written to disk or uploaded to S3. The following fields are redacted by default:

- **Database endpoints** (`endpoint`, `reader_endpoint`) → masked to `<masked-endpoint>`
- **Client IP addresses** in connection activity data → SHA-256 hash (first 8 chars)
- **KMS key ARNs** → trimmed to key ID only (no account ID or region)
- **Password hashes** in database health data → replaced with `<redacted>`
- **Query text** — a `query_hash` field is added alongside each query for cross-referencing. The query text itself is **not removed** because `pg_stat_statements` stores only the parameterized form (e.g. `UPDATE t SET col = $1 WHERE id = $2`) which contains no customer data.

**What is NOT redacted**:
- Table, column, and schema names
- All numeric metric values
- Parameter names and settings
- Database passwords are never written to any output file — retrieved from Secrets Manager at runtime only

To **skip redaction** (e.g. for internal analysis where you need raw endpoints):

```bash
./collect-and-share.sh --no-redact
```

## Cleanup

To remove all deployed resources:

```bash
# Delete the CloudFormation stack (terminates EC2 instance, removes IAM roles, SGs, and any SSM VPC endpoints created by the stack)
aws cloudformation delete-stack \
  --stack-name wal-db-stats-collection \
  --region <your-region>

# Wait for deletion to complete
aws cloudformation wait stack-delete-complete \
  --stack-name wal-db-stats-collection \
  --region <your-region>

# Optionally delete the S3 data bucket (contains collected metrics — delete after SA review is complete)
# Step 1: Remove all versioned objects and delete markers (required if bucket has versioning enabled)
aws s3api delete-objects \
  --bucket wal-db-stats-collection-<account-id> \
  --region <your-region> \
  --delete "$(aws s3api list-object-versions \
    --bucket wal-db-stats-collection-<account-id> \
    --region <your-region> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

# Step 2: Remove delete markers
aws s3api delete-objects \
  --bucket wal-db-stats-collection-<account-id> \
  --region <your-region> \
  --delete "$(aws s3api list-object-versions \
    --bucket wal-db-stats-collection-<account-id> \
    --region <your-region> \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

# Step 3: Delete the bucket
aws s3 rb s3://wal-db-stats-collection-<account-id> --region <your-region>
```

> **Note**: The temporary code bucket (`wal-db-stats-code-<account-id>`) is automatically deleted by the deploy script after stack creation completes. If it was not cleaned up automatically, delete it manually: `aws s3 rb s3://wal-db-stats-code-<account-id> --force --region <your-region>`

> **Note**: If you created a NAT Gateway, EIP, private subnet, or route table outside of CloudFormation for this deployment, those resources must be deleted manually — they are not managed by the stack.

## Cost Estimation

All resources are deployed into your AWS account. Costs depend on how long you leave the stack running. The following estimates are based on **us-east-1** On-Demand pricing for a **1-day** collection run.

| Resource | Rate | Typical usage (1 day) | Estimated cost |
|----------|------|----------------------|----------------|
| EC2 t3.medium | $0.0416/hr | 24 hrs | ~$1.00 |
| S3 storage | $0.023/GB-month | <100 MB of metrics data | <$0.01 |
| S3 requests | $0.005/1K PUT | ~50 files uploaded | <$0.01 |
| CloudWatch API | $0.01/1K metrics | ~1,000 metric queries | ~$0.01 |
| Performance Insights — 7-day retention | Free | Included with RDS/Aurora | $0 |
| Performance Insights — API calls | $0.01/1K calls | ~400 API calls per run | <$0.01 |
| **SSM VPC endpoints** (Option 3 only) | $0.01/hr × 3 endpoints | 24 hrs | ~$0.72 |
| **NAT Gateway** (if created for this deployment) | $0.045/hr + $0.045/GB | 24 hrs + ~1 GB data | ~$1.13 |

**Estimated total cost per day:**

| Deployment option | Cost/day |
|---|---|
| Option 1 — public subnet | ~$1.00–$1.05 |
| Option 2 — private subnet + NAT (NAT pre-existing) | ~$1.00–$1.05 |
| Option 2 — private subnet + NAT (NAT created for this) | ~$2.13–$2.18 |
| Option 3 — private subnet + NAT + SSM endpoints | ~$1.72–$1.77 (NAT pre-existing) |

> **Note**: To minimize cost, delete the stack as soon as the SA has confirmed receipt of the data. The S3 data bucket has a 30-day lifecycle expiry — objects are deleted automatically.

## What's New

### v2.0

- **RDS Multi-AZ DB Cluster support** — fleet discovery, non-invasive collection (CloudWatch from writer, Performance Insights from all 3 instances), and correct WAL lens selection for RDS Multi-AZ DB Clusters
- **Private subnet deployment** (`--no-public-ip`) — deploy without a public IP or SSH key pair; connect via SSM Session Manager. Key pair and CIDR are no longer required
- **SSM VPC endpoint automation** — deploy script auto-configures pre-existing SSM endpoints (Pattern A); `--create-ssm-endpoints` flag has CFN create them when none exist (Pattern B)
- **Code bucket security** — public access blocked and server-side encryption enabled at creation; bucket deleted automatically after stack creation
- **Stack-scoped log group** — prevents CloudWatch log group conflicts between multiple stacks

## Troubleshooting

**Instance setup not complete after 10 minutes**
```bash
# Check UserData logs
ssh -i <keypair>.pem ec2-user@<ip>
sudo tail -f /var/log/user-data.log
```

**UserData hangs at `dnf update`, `git clone`, or AWS API calls**
This is the most common symptom of a NACL blocking return traffic (ephemeral ports). The instance security group allows outbound TCP/443 and TCP/5432, but NACLs are stateless — return packets on ports 1024–65535 must be explicitly permitted inbound.
- Check the NACL associated with your subnet in the VPC console
- Ensure inbound ephemeral ports 1024–65535 TCP are allowed from 0.0.0.0/0
- See the [Network ACL requirements](#network-acl-nacl-requirements) section above for the full rule set

**Collection script not found**
The instance may still be setting up. Wait a few more minutes and check `/var/log/user-data.log`.

**CloudWatch or Performance Insights returns no data**
- Ensure Performance Insights is enabled on your RDS/Aurora cluster
- Verify if permissions `pi:GetResourceMetrics` and `cloudwatch:GetMetricStatistics` are explicitly denied anywhere

**Invasive collection fails**
- Confirm the Secrets Manager ARN is correct and the secret contains a `password` key
- Ensure the EC2 instance security group can reach the database endpoint on its port (default port: 5432)
- If the error mentions `track_functions`: set `track_functions = all` in the DB parameter group for RDS for PostgreSQL, or the cluster parameter group for Aurora PostgreSQL. This is a dynamic parameter — no reboot required.
- If the output mentions `[Optional] track_activity_query_size`: this is a recommended improvement, not a blocking error — collection will still run without it. To capture the full text of very long SQL statements that would otherwise be truncated during monitoring, set `track_activity_query_size = 102400` in the DB parameter group for RDS for PostgreSQL, or the cluster parameter group for Aurora PostgreSQL, then reboot the DB instance [REBOOT REQUIRED]. 

## DISCLAIMER OF WARRANTIES AND LIABILITY

This code is provided solely for prototyping and proof-of-concept purposes. By accessing, downloading, or using this code, you acknowledge and agree to the following terms:

NO WARRANTY This code is provided "as-is," without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, or non-infringement. Amazon Web Services, Inc. and its affiliates ("AWS") make no representations or warranties regarding the accuracy, reliability, completeness, or suitability of this code for any purpose.

LIMITATION OF LIABILITY AWS and its affiliates shall not be liable for any direct, indirect, incidental, special, consequential, or exemplary damages arising out of or in connection with the use, misuse, or inability to use this code, even if advised of the possibility of such damages.

NO SUPPORT AWS and its affiliates do not provide technical support, maintenance, updates, or bug fixes for this code. Use of this code is entirely at the discretion and risk of the end user.

CUSTOMER RESPONSIBILITY It is the sole responsibility of the customer to evaluate, test, and validate this code in non-production (lower) environments prior to any deployment in production systems. Deployment of this code in any environment, including production, is undertaken entirely at the customer's own risk.

INDEPENDENT USE This code does not constitute professional advice, and customers are encouraged to engage qualified technical personnel to assess its suitability for their specific use case.

By using this code, you confirm that you have read, understood, and agreed to the terms set forth in this disclaimer.