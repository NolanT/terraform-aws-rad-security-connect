locals {
  bucket_name = "ksoc-eks-${random_id.uniq.hex}"
  regions     = [for region in var.eks_audit_logs_regions : "logs.${region}.amazonaws.com"]
}

resource "random_id" "uniq" {
  byte_length = 4
}

data "aws_cloudwatch_log_groups" "eks" {
  count                 = var.enable_eks_audit_logs_pipeline ? 1 : 0
  log_group_name_prefix = "/aws/eks/"
}

resource "aws_kinesis_firehose_delivery_stream" "firehose" {
  count       = var.enable_eks_audit_logs_pipeline ? 1 : 0
  name        = "ksoc-audit-logs"
  destination = "extended_s3"
  tags        = var.tags

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose[0].arn
    bucket_arn = aws_s3_bucket.audit_logs[0].arn

    buffering_interval = 60
    buffering_size     = 5 // MiB
  }
}

resource "aws_s3_bucket" "audit_logs" {
  count         = var.enable_eks_audit_logs_pipeline ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = true
  tags = merge(var.tags, {
    ksoc-data-type = "eks-audit-logs"
  })
}

resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  count  = var.enable_eks_audit_logs_pipeline ? 1 : 0
  bucket = aws_s3_bucket.audit_logs[0].id
  versioning_configuration {
    status = var.eks_audit_logs_bucket_versioning_enabled ? "Enabled" : "Disabled"
  }
}

data "aws_iam_policy_document" "firehose_assume" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "firehose_to_s3" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket",
      "s3:ListBucketMultipartUploads", "s3:PutObject"
    ]
    resources = [aws_s3_bucket.audit_logs[0].arn, "${aws_s3_bucket.audit_logs[0].arn}/*"]
  }
}

# trivy:ignore:AVD-AWS-0057
resource "aws_iam_role" "firehose" {
  count              = var.enable_eks_audit_logs_pipeline ? 1 : 0
  name               = "ksoc-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume[0].json
  inline_policy {
    name   = "ksoc-firehose-to-s3-policy"
    policy = data.aws_iam_policy_document.firehose_to_s3[0].json
  }
  tags = var.tags
}

data "aws_iam_policy_document" "cloudwatch_assume" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = local.regions
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "logs_to_firehose" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["firehose:PutRecord"]
    resources = [aws_kinesis_firehose_delivery_stream.firehose[0].arn]
  }
}

resource "aws_iam_role" "cloudwatch" {
  count              = var.enable_eks_audit_logs_pipeline ? 1 : 0
  name               = "ksoc-cloudwatch-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_assume[0].json
  inline_policy {
    name   = "ksoc-cloudwatch-logs-to-firehose-policy"
    policy = data.aws_iam_policy_document.logs_to_firehose[0].json
  }
  tags = var.tags
}

resource "aws_cloudwatch_log_subscription_filter" "subscription_filter" {
  for_each = var.enable_eks_audit_logs_pipeline && !var.eks_audit_logs_multi_region ? {
    for name in data.aws_cloudwatch_log_groups.eks[0].log_group_names : name => name
  } : {}

  name            = "ksoc-audit-logs"
  role_arn        = aws_iam_role.cloudwatch[0].arn
  log_group_name  = each.key
  filter_pattern  = var.eks_audit_logs_filter_pattern
  destination_arn = aws_kinesis_firehose_delivery_stream.firehose[0].arn
  distribution    = "Random"
}

# Cross-account connectivity.
data "aws_iam_policy_document" "ksoc_s3_access" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.audit_logs[0].arn, "${aws_s3_bucket.audit_logs[0].arn}/*"]
  }
}

resource "aws_iam_policy" "ksoc_s3_access" {
  count  = var.enable_eks_audit_logs_pipeline ? 1 : 0
  policy = data.aws_iam_policy_document.ksoc_s3_access[0].json
  tags   = var.tags
}

data "aws_iam_policy_document" "ksoc_assume" {
  count = var.enable_eks_audit_logs_pipeline ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.rad-security_eks_audit_logs_assumed_role_arn]
    }
  }
}

resource "aws_iam_role" "ksoc_s3_access" {
  count                = var.enable_eks_audit_logs_pipeline ? 1 : 0
  name                 = "ksoc-audit-logs"
  path                 = "/"
  max_session_duration = 3600
  tags                 = var.tags

  assume_role_policy = data.aws_iam_policy_document.ksoc_assume[0].json
}

resource "aws_iam_role_policy_attachment" "ksoc_s3_access" {
  count      = var.enable_eks_audit_logs_pipeline ? 1 : 0
  role       = aws_iam_role.ksoc_s3_access[0].name
  policy_arn = aws_iam_policy.ksoc_s3_access[0].arn
}
