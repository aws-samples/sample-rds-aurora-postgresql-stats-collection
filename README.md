# Database Statistics, Configuration, Performance Metrics Collection Guide

> **Disclaimer**: This tool collects database metrics and configuration data from your AWS environment for Well-Architected review purposes. Review the README.MD carefully and test against your staging/QA environment first to understand the scipts and data collected. Review the data collected before sharing and ensure it complies with your organization's data sharing policies. Please issue a support case to share any data collected to AWS. If any concerns, please reach back to your account SA and proceed with ad-hoc data collection using the issued support case.

## What this does

Deploys a lightweight EC2 instance in your AWS account that:
- Discovers all PostgreSQL databases (Aurora and RDS) in your account/region
- Collects CloudWatch metrics, Performance Insights data, and database configuration
- Collects deeper database statistics (requires AWS Secrets Manager to access DB from your account)
- Uploads collected data to an S3 bucket in your account for review

## Prerequisites

- AWS CLI configured with your account credentials
- An EC2 Key Pair in your target region
- A VPC with a public subnet
- IAM permissions: EC2, CloudFormation, S3, RDS, CloudWatch, Performance Insights

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
| 22 | TCP | Your IP/32 | SSH access |
| 1024–65535 | TCP | 0.0.0.0/0 | Ephemeral ports — return traffic for outbound HTTPS and PostgreSQL connections |

> **Note**: The default VPC NACL allows all traffic in both directions — no changes needed if you are using the default NACL. Custom NACLs that deny ephemeral port return traffic are the most common cause of silent connectivity failures (instance appears to deploy successfully but `dnf`, `git clone`, and AWS API calls hang or time out).

## Step 1: Deploy the data collection instance

Clone the repository and run the deploy script:

```bash
git clone https://github.com/aws-samples/sample-rds-aurora-postgresql-stats-collection.git
cd sample-rds-aurora-postgresql-stats-collection

bash deployment/deploy-db-stats-collection.sh \
  --key-pair <your-key-pair-name> \
  --vpc-id <your-vpc-id> \
  --subnet-id <your-public-subnet-id> \
  --allowed-cidr <your-ip>/32 \
  --region <your-region> \
  --db-port 5432          # optional: only needed if your RDS/Aurora endpoint uses a non-standard port
```

The script will:
1. Package the repo contents and upload to S3 (fallback if the EC2 instance can't reach GitHub)
2. Deploy a CloudFormation stack (`wal-db-stats-collection`) with a `t3.medium` EC2 instance
3. The EC2 instance clones the repo from GitHub on boot (falls back to S3 if GitHub is unreachable)
4. Print the SSH command, instance IP, and data S3 bucket name on completion

Wait ~10 minutes for the instance to finish setup after the stack completes.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--key-pair` | Yes | — | EC2 Key Pair name for SSH access |
| `--vpc-id` | Yes | — | VPC ID where the EC2 instance will be deployed. **Must be the same VPC as your RDS/Aurora cluster** so the instance can reach the database endpoint. |
| `--subnet-id` | Yes | — | Subnet ID within the VPC above. Two options: **(1) Public subnet** (with an Internet Gateway) — instance gets a public IP, SSH works directly from your machine. **(2) Private subnet with a [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html)** — SSH is not possible without a bastion or VPN. Outbound traffic routes via NAT for S3 uploads and package installation. Use [AWS Systems Manager Session Manager](#accessing-the-instance-in-a-private-subnet) to connect. |
| `--allowed-cidr` | Yes | — | CIDR allowed for SSH inbound on port 22. **Must be your specific IP** (e.g. `203.0.113.42/32`). `0.0.0.0/0` is rejected — open SSH access is a security risk. Find your IP with `curl -s ifconfig.me`. |
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

> **Note**: Session Manager requires the instance to reach the SSM endpoints. In a private subnet with a NAT Gateway this works automatically via the NAT outbound route.

The EC2 instance role already includes the `AmazonSSMManagedInstanceCore` policy, so SSM is enabled automatically.

**AWS Console**
1. Open the [EC2 console](https://console.aws.amazon.com/ec2/) → Instances
2. Select the instance → Connect → Session Manager → Connect

## Step 3: Run database statistics and metrics collection 

Database statistics and metrics collection gathers CloudWatch metrics (7 days), Performance Insights, and RDS/Aurora configuration for all PostgreSQL databases discovered in your account. Additionally, it collects database statistics and query performance data using extension [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) and [PGPerfStatsSnapper](https://github.com/aws-samples/aurora-and-database-migration-labs/blob/master/Code/PGPerfStatsSnapper/README.md) for performance and workload analysis. This requires database credentials stored in AWS Secrets Manager.

> **Note**: Database statistics and metrics collection runs read-only queries against your database. No data is modified. Queries are lightweight and designed to have minimal performance impact. Test with your QA/test environment to understand the metrics collected before running against production. If you have concerns about direct database access, see [(Optional) Collect CloudWatch metrics only](#optional-collect-cloudwatch-metrics-only) — however, skipping in-depth database statistics and metrics collection limits the SA's ability to identify slow queries and top SQL by execution time (`pg_stat_statements`), table-level bloat and sequential scan patterns (`pg_stat_user_tables`), unused and redundant indexes (`pg_stat_user_indexes`), checkpoint and buffer write pressure (`pg_stat_bgwriter`), and historical workload trends from PGPerfStatsSnapper snapshots. These are the primary inputs for Well Architected Review tuning recommendations.

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
| `cluster-id` | Yes | RDS cluster or instance identifier |
| `db-host` | Yes | Database endpoint hostname |
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

Database statistics and metrics collection requires **two runs** of `./collect-and-share.sh`:

1. **Run 1 (setup only)** — installs the PGSnapper cron job and runs an initial snapshot to verify connectivity. **No data collection happens on this run** — no non-invasive metrics, no database statistics, no schema or query performance data. This keeps Run 1 fast and avoids collecting data that would be stale by Run 2.
2. **Wait** — allow snapshots to accumulate for at least `pgsnapper-min-days` worth of data.
3. **Run 2 (collect everything)** — collects **all** data with aligned timestamps: non-invasive metrics (CloudWatch, Performance Insights, configuration) for the entire fleet, plus invasive data (database statistics, schema, query performance, PGSnapper analysis) for flagged clusters. Because both non-invasive and invasive data are collected in the same run, all metrics share the same time window.

> **Note**: If the initial snapshot fails during Run 1 (bad credentials, network issue, etc.), the cron job will **not** be installed. Fix the underlying issue and re-run `./collect-and-share.sh` — it will detect that setup is still needed and retry.

With the example above (`pgsnapper-min-days=1`, `pgsnapper-interval=60`), wait at least 1 day between runs. For a quick test, use `pgsnapper-min-days=0.01` (~15 minutes) and `pgsnapper-interval=1` (1 minute interval).

```bash
# Run 1 — setup only: installs cron, verifies connectivity (no data collection)
./collect-and-share.sh

# Wait for pgsnapper-min-days worth of snapshots...

# Run 2 — collects all data (non-invasive + invasive) with aligned timestamps
./collect-and-share.sh
```

Collected data is automatically uploaded to:
```
s3://wal-db-stats-collection-<account-id>/db-stats/<timestamp>/
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

> **Note**: Removing the flag file only prevents invasive collection from running — it does not affect any PGSnapper cron job that may have already been installed. If the cron job was set up during a previous `collect-and-share.sh` run, you can choose to remove it too if any concerns:
> ```bash
> crontab -l | grep -v 'pgsnapper_snap.sh' | crontab -
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
- PGPerfStatsSnapper workload snapshots (historical query performance trends)

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
# Delete the CloudFormation stack (terminates EC2 instance, removes IAM roles/SGs)
aws cloudformation delete-stack \
  --stack-name wal-db-stats-collection \
  --region <your-region>

# Optionally delete the S3 buckets
aws s3 rb s3://wal-db-stats-collection-<account-id> --force
aws s3 rb s3://wal-db-stats-code-<account-id> --force
```

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