#!/usr/bin/env bash

# Create/secure Terraform remote state resources (S3 bucket + DynamoDB table)
# - Idempotent: skips creation if resources already exist
# - Hardened: blocks public access, enables versioning, and configures encryption
#
# Usage:
#   scripts/setup-tf-state.sh -b <bucket> -t <table> -r <region> [--kms-key-arn <arn>]
#
# Example:
#   scripts/setup-tf-state.sh \
#     -b clms-tfstate-123456 \
#     -t clms-tf-locks \
#     -r us-east-1
#
# Requirements: awscli v2 configured with credentials

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 -b <bucket> -t <table> -r <region> [--kms-key-arn <arn>]

  -b  S3 bucket name for Terraform state
  -t  DynamoDB table name for Terraform state locks
  -r  AWS region (e.g., us-east-1)
      When using a region other than us-east-1, the bucket is created with a location constraint.
  --kms-key-arn  Optional KMS CMK ARN for bucket default encryption (otherwise SSE-S3 is used)

Examples:
  $0 -b clms-tfstate-123456 -t clms-tf-locks -r us-east-1
  $0 -b clms-tfstate-prod -t clms-tf-locks -r eu-west-1 --kms-key-arn arn:aws:kms:eu-west-1:123456789012:key/uuid
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}

## Defaults (edit these to your preferred names)
DEFAULT_BUCKET="clms-tfstate"
DEFAULT_TABLE="clms-tf-locks"
DEFAULT_REGION="us-east-1"

# Effective values (overridable via flags)
BUCKET="$DEFAULT_BUCKET"
TABLE="$DEFAULT_TABLE"
REGION="$DEFAULT_REGION"
KMS_ARN=""

while (( "$#" )); do
  case "$1" in
    -b) BUCKET="$2"; shift 2;;
    -t) TABLE="$2"; shift 2;;
    -r) REGION="$2"; shift 2;;
    --kms-key-arn) KMS_ARN="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || -z "$TABLE" || -z "$REGION" ]]; then
  echo "Missing required args" >&2
  usage
  exit 1
fi

require_cmd aws

echo "[+] Ensuring S3 bucket: $BUCKET in $REGION"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    Bucket exists"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  echo "    Created bucket"
fi

echo "[+] Blocking public access on bucket"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "[+] Enabling versioning"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

echo "[+] Configuring default encryption"
if [[ -n "$KMS_ARN" ]]; then
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KMS_ARN\"}}]}"
else
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
fi

echo "[+] Ensuring DynamoDB lock table: $TABLE in $REGION"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "    Table exists"
else
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  echo "    Waiting for table to be ACTIVE ..."
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi

cat <<NEXT

Done.

Initialize Terraform backend with:

  cd infra/terraform
  terraform init -migrate-state \
    -backend-config="bucket=$BUCKET" \
    -backend-config="key=clms/terraform.tfstate" \
    -backend-config="region=$REGION" \
    -backend-config="dynamodb_table=$TABLE"

NEXT
