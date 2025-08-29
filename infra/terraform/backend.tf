// Remote state backend (S3 + DynamoDB lock)
// NOTE: Replace bucket and dynamodb_table with your resources,
// or supply them via `-backend-config` flags on `terraform init`.
terraform {
  backend "s3" {
    bucket               = "CHANGE_ME_TFSTATE_BUCKET"
    key                  = "clms/terraform.tfstate"
    region               = "us-east-1"
    dynamodb_table       = "CHANGE_ME_TF_LOCKS"
    encrypt              = true
    workspace_key_prefix = "clms"
  }
}

