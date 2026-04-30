#!/bin/bash

# Deploy customer data collection CloudFormation stack for GenAI WAL Review

set -e

# Default values
STACK_NAME="wal-db-stats-collection"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/../cfn/db-stats-collection.yaml"
REGION="us-east-1"
INSTANCE_TYPE="t3.medium"
ENABLE_SCHEDULED="true"
SCHEDULE="0 6 * * *"
CODE_KEY="wal-db-stats-collection.zip"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --key-pair)
            KEY_PAIR="$2"
            shift 2
            ;;
        --vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        --allowed-cidr)
            ALLOWED_CIDR="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            shift 2
            ;;
        --sa-data-bucket)
            SA_DATA_BUCKET="$2"
            shift 2
            ;;
        --enable-scheduled)
            ENABLE_SCHEDULED="$2"
            shift 2
            ;;
        --schedule)
            SCHEDULE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy customer data collection environment for GenAI WAL Review"
            echo ""
            echo "Options:"
            echo "  --stack-name STACK_NAME         CloudFormation stack name (default: wal-db-stats-collection)"
            echo "  --region REGION                 AWS region (default: us-east-1)"
            echo "  --key-pair KEY_PAIR             EC2 Key Pair name (required)"
            echo "  --vpc-id VPC_ID                 VPC ID (required)"
            echo "  --subnet-id SUBNET_ID           Subnet ID (public subnet recommended)"
            echo "  --instance-type TYPE            Instance type (default: t3.medium)"
            echo "  --allowed-cidr CIDR             Allowed CIDR for SSH (required; e.g. \$(curl -s ifconfig.me)/32 — 0.0.0.0/0 is rejected)
  --db-port PORT                  PostgreSQL port on target RDS/Aurora endpoint for invasive collection (default: 5432)"
            echo "  --sa-data-bucket BUCKET         S3 bucket name for SA data sharing (optional)"
            echo "  --enable-scheduled true/false   Enable scheduled data collection (default: true)"
            echo "  --schedule 'CRON'               Cron schedule for data collection (default: '0 6 * * *')"
            echo "  --help                          Show this help message"
            echo ""
            echo "Customer Data Collection Workflow:"
            echo "  1. Customer deploys data collection environment"
            echo "  2. Customer runs fleet discovery and data collection"
            echo "  3. Customer shares data with SA via S3 bucket"
            echo "  4. SA runs GenAI analysis in separate environment"
            echo "  5. SA provides comprehensive reports back to customer"
            echo ""
            echo "Prerequisites:"
            echo "  - AWS CLI configured with RDS/CloudWatch/PI permissions"
            echo "  - VPC with public subnet for EC2 instance"
            echo "  - EC2 Key Pair for SSH access"
            echo "  - PostgreSQL databases in AWS account"
            echo ""
            echo "Example:"
            echo "  $0 --key-pair my-keypair --vpc-id vpc-12345 --subnet-id subnet-67890 --allowed-cidr \$(curl -s ifconfig.me)/32"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$KEY_PAIR" ]]; then
    echo "❌ Error: --key-pair is required"
    exit 1
fi

if [[ -z "$VPC_ID" ]]; then
    echo "❌ Error: --vpc-id is required"
    exit 1
fi

if [[ -z "$SUBNET_ID" ]]; then
    echo "❌ Error: --subnet-id is required"
    exit 1
fi

if [[ -z "$ALLOWED_CIDR" ]]; then
    echo "❌ Error: --allowed-cidr is required"
    echo "   Specify your IP in CIDR notation, e.g. --allowed-cidr \$(curl -s ifconfig.me)/32"
    exit 1
fi

if [[ "$ALLOWED_CIDR" == "0.0.0.0/0" ]]; then
    echo "❌ Error: --allowed-cidr 0.0.0.0/0 is not allowed — open SSH access is a security risk."
    echo "   Specify your IP in CIDR notation, e.g. --allowed-cidr \$(curl -s ifconfig.me)/32"
    exit 1
fi
SA_DATA_BUCKET=${SA_DATA_BUCKET:-""}

# Upload code to S3 as fallback (CFN tries git clone first, falls back to S3)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
CODE_BUCKET="wal-db-stats-code-${ACCOUNT_ID}"
ZIP_NAME="wal-db-stats-collection.zip"
REPO_ROOT="$SCRIPT_DIR/.."
ZIP_PATH="$REPO_ROOT/$ZIP_NAME"

# Create zip from repo contents if it doesn't already exist
if [ ! -f "$ZIP_PATH" ]; then
    echo "📦 Creating code package from repo contents..."
    (cd "$REPO_ROOT" && zip -r "$ZIP_NAME" \
        deployment/collect-and-share.sh \
        deployment/enable-invasive-collection.sh \
        deployment/deploy-db-stats-collection.sh \
        cfn/db-stats-collection.yaml \
        scripts/non_invasive_collector.py \
        scripts/invasive_collector.py \
        scripts/pgsnapper_sql_fixes/ \
        utils/fleet_discovery.py \
        requirements.txt \
        README.md \
        -x "*.DS_Store*" -q)
    echo "   Created $ZIP_NAME"
fi

echo "📦 Uploading code to S3..."
aws s3 mb "s3://$CODE_BUCKET" --region "$REGION" 2>/dev/null || true
aws s3 cp "$ZIP_PATH" "s3://$CODE_BUCKET/$CODE_KEY" --region "$REGION"

# If customer data bucket already exists, pass it explicitly to prevent CFN from trying to create it
CUSTOMER_DATA_BUCKET_NAME="${STACK_NAME}-${ACCOUNT_ID}"
if [ -n "$SA_DATA_BUCKET" ]; then
    RESOLVED_DATA_BUCKET="$SA_DATA_BUCKET"
elif aws s3api head-bucket --bucket "$CUSTOMER_DATA_BUCKET_NAME" --region "$REGION" 2>/dev/null; then
    echo "ℹ️  Customer data bucket already exists, reusing: $CUSTOMER_DATA_BUCKET_NAME"
    SA_DATA_BUCKET="$CUSTOMER_DATA_BUCKET_NAME"
    RESOLVED_DATA_BUCKET="$CUSTOMER_DATA_BUCKET_NAME"
else
    RESOLVED_DATA_BUCKET="$CUSTOMER_DATA_BUCKET_NAME"
fi

echo "🚀 Deploying Customer Data Collection for GenAI WAL Review"
echo "========================================================="
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "Key Pair: $KEY_PAIR"
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Allowed CIDR: $ALLOWED_CIDR"
echo "SA Data Bucket: ${SA_DATA_BUCKET:-'Will be auto-created'}"
echo "Scheduled Collection: $ENABLE_SCHEDULED"
echo "Schedule: $SCHEDULE"
echo ""

# Check if stack exists
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "📝 Stack exists, updating..."
    OPERATION="update-stack"
else
    echo "🆕 Creating new stack..."
    OPERATION="create-stack"
fi

# Deploy stack
echo "⚡ Deploying CloudFormation stack..."
aws cloudformation "$OPERATION" \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE_FILE" \
    --parameters \
        "ParameterKey=KeyPairName,ParameterValue=$KEY_PAIR" \
        "ParameterKey=VpcId,ParameterValue=$VPC_ID" \
        "ParameterKey=SubnetId,ParameterValue=$SUBNET_ID" \
        "ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE" \
        "ParameterKey=AllowedCIDR,ParameterValue=$ALLOWED_CIDR" \
        "ParameterKey=DBPort,ParameterValue=${DB_PORT:-5432}" \
        "ParameterKey=SADataBucket,ParameterValue=$SA_DATA_BUCKET" \
        "ParameterKey=ResolvedDataBucketName,ParameterValue=$RESOLVED_DATA_BUCKET" \
        "ParameterKey=EnableScheduledCollection,ParameterValue=$ENABLE_SCHEDULED" \
        "ParameterKey=CollectionSchedule,ParameterValue=$SCHEDULE" \
        "ParameterKey=CodeSourceBucket,ParameterValue=$CODE_BUCKET" \
        "ParameterKey=CodeSourceKey,ParameterValue=$CODE_KEY" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION"

echo "⏳ Waiting for stack operation to complete..."
aws cloudformation wait "stack-${OPERATION%-stack}-complete" \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

# Get outputs
echo ""
echo "✅ Stack deployment completed!"
echo ""
echo "📋 Stack Outputs:"
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

# Get specific outputs for next steps
PUBLIC_IP=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIP`].OutputValue' \
    --output text)

CUSTOMER_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`CustomerDataBucket`].OutputValue' \
    --output text)

echo ""
echo "🔗 Customer Data Collection Workflow:"
echo "===================================="
echo "1. SSH to the data collection instance:"
echo "   ssh -i $KEY_PAIR.pem ec2-user@$PUBLIC_IP"
echo ""
echo "2. Run data collection and sharing:"
echo "   cd /home/ec2-user/wal-db-stats-collection"
echo "   ./collect-and-share.sh"
echo ""
echo "3. (Optional) Enable invasive collection (requires DB credentials in Secrets Manager):"
echo "   NOTE: Wrap db-secret-arn in single quotes if it contains '!' (RDS managed secrets)"
echo "   ./enable-invasive-collection.sh \\"
echo "     <cluster-id> \\"
echo "     <db-host> \\"
echo "     <db-user> \\"
echo "     '<db-secret-arn>' \\"
echo "     [db-name] \\"
echo "     [pgsnapper-min-days] \\"
echo "     [pgsnapper-interval]"
echo ""
echo "   Invasive collection requires 2 runs of ./collect-and-share.sh:"
echo "     1st run: installs PGSnapper cron job to start taking snapshots"
echo "     Wait:    allow snapshots to accumulate (pgsnapper-min-days worth of data)"
echo "     2nd run: analyzes snapshots and uploads the full dataset"
echo ""
echo "4. Verify data collection:"
echo "   ls -la data/"
echo "   aws s3 ls s3://$CUSTOMER_BUCKET/db-stats/"
echo ""
echo "5. Share S3 bucket access with SA:"
echo "   Bucket: $CUSTOMER_BUCKET"
echo "   Path: s3://$CUSTOMER_BUCKET/db-stats/"
echo ""
echo "6. SA runs analysis in separate environment using shared data"
echo ""
echo "📊 Metrics Collection Features:"
echo "=========================="
echo "- Fleet discovery across all PostgreSQL databases"
echo "- CloudWatch metrics collection (7 days)"
echo "- Performance Insights metrics collection"
echo "- Database configuration and metadata"
echo "- pg_stat_statements and PGPerfStatsSnapper support for in-depth database statistics, query performance, and metrics collection"
echo "- Automated S3 upload for SA sharing"
echo ""
echo "📋 Collection Types:"
echo "=================="
echo "- Non-invasive: CloudWatch + Performance Insights only"
echo "- Invasive: Includes DB slow queries + pg_stat_statements + PGPerfStatsSnapper"
echo "- To enable invasive: ./enable-invasive-collection.sh <cluster-id> <host> <user> <db-secret-arn> [pgsnapper-min-days] [pgsnapper-interval]"
echo ""
if [[ "$ENABLE_SCHEDULED" == "true" ]]; then
    echo "⏰ Scheduled Collection: Enabled ($SCHEDULE)"
    echo "   Data collection will run automatically and upload to S3"
fi
echo ""
echo "🔒 Security & Privacy:"
echo "====================="
echo "- Read-only queries for database statistics, query performance, and metrics collection"
echo "- Customer retains full control of data"
echo "- SA receives the metrics data shared without any database access"
echo ""
echo "📞 Next Steps:"
echo "============="
echo "Refer to README.md for detailed next steps"
echo "1. (Optional)Enable in-depth database statistics and metrics collection (DB slow queries + pg_stat_statements + PGPerfStatsSnapper): ./enable-invasive-collection.sh <cluster-id> <host> <user> <db-secret-arn> [pgsnapper-min-days] [pgsnapper-interval]"
echo "2. Run database statistics and metrics collection: ./collect-and-share.sh"
echo "3. Provide SA with S3 bucket access: $CUSTOMER_BUCKET"
echo "4. SA will process your data and perform analysis"
echo "5. SA will provide comprehensive Well Architected Review reports and recommendations"
echo ""