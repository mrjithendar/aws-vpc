#--------------------------------------------------------------------
# VPC Flow Logs -> S3 (Parquet, hourly partitions; query with Athena)
#--------------------------------------------------------------------
locals {
  flow_log_bucket = "${local.name}-vpc-flowlogs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "flow_logs" {
  #checkov:skip=CKV_AWS_18:Access logging on a log bucket would create a logging loop
  #checkov:skip=CKV_AWS_144:Cross-region replication is not needed for flow logs
  #checkov:skip=CKV_AWS_145:SSE-S3 is sufficient; SSE-KMS needs extra key policy for log delivery
  #checkov:skip=CKV2_AWS_62:No event notifications needed
  #checkov:skip=CKV_AWS_21:Objects are write-once logs; versioning adds cost without benefit
  count         = var.enable_flow_logs ? 1 : 0
  bucket        = local.flow_log_bucket
  force_destroy = false

  tags = {
    Name = local.flow_log_bucket
  }
}

resource "aws_s3_bucket_ownership_controls" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count                   = var.enable_flow_logs ? 1 : 0
  bucket                  = aws_s3_bucket.flow_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "expire-flow-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.flow_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow_logs[0].arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.flow_logs[0].arn, "${aws_s3_bucket.flow_logs[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.flow_logs]
}

resource "aws_flow_log" "vpc" {
  count                    = var.enable_flow_logs ? 1 : 0
  vpc_id                   = aws_vpc.vpc.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flow_logs[0].arn
  max_aggregation_interval = 60

  # Default v2 fields plus the ones that matter for NAT/EKS troubleshooting
  # (pkt-* addresses show the real pod/source behind NAT and ENIs).
  log_format = join(" ", [
    "$${version}", "$${account-id}", "$${interface-id}", "$${srcaddr}", "$${dstaddr}",
    "$${srcport}", "$${dstport}", "$${protocol}", "$${packets}", "$${bytes}",
    "$${start}", "$${end}", "$${action}", "$${log-status}",
    "$${vpc-id}", "$${subnet-id}", "$${az-id}", "$${instance-id}", "$${tcp-flags}",
    "$${pkt-srcaddr}", "$${pkt-dstaddr}", "$${flow-direction}", "$${traffic-path}",
    "$${pkt-src-aws-service}", "$${pkt-dst-aws-service}",
  ])

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = {
    Name = "${local.name}-flow-log"
  }

  depends_on = [aws_s3_bucket_policy.flow_logs]
}
