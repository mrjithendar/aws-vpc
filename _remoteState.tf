terraform {
  # Partial configuration: bucket/key/region come from backend/<env>.hcl so each
  # environment gets its own state file.
  #   terraform init -backend-config=backend/dev.hcl
  backend "s3" {
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB table needed
  }
}
