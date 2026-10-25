data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Bucket names are global; the account ID keeps this one unique.
  bucket_name = "${var.prefix}-snapshots-${data.aws_caller_identity.current.account_id}"
  # Named S3 client in the Elasticsearch keystore (s3.client.<name>.*).
  s3_client = "demo"
}

# -----------------------------------------------------------------------------
# S3 bucket in our AWS account (not the ECH-managed found-snapshots repository)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "snapshots" {
  bucket = local.bucket_name
  # Demo data only: let terraform destroy remove the snapshots too.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Customer-managed key so the console shows SSE-KMS with a named key
# (alias/<prefix>-snapshots) rather than the default S3-managed encryption.
# The default key policy delegates access to IAM, so the IAM user policy below grants use.
resource "aws_kms_key" "snapshots" {
  description             = "Encrypts Elasticsearch snapshots in s3://${local.bucket_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "snapshots" {
  name          = "alias/${var.prefix}-snapshots"
  target_key_id = aws_kms_key.snapshots.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.snapshots.arn
    }
    # Bucket Key cuts KMS request costs for the many small snapshot blobs.
    bucket_key_enabled = true
  }
}

# Shown under Permissions -> Bucket policy: reject uploads that ask for any
# encryption other than SSE-KMS. Elasticsearch sends no SSE header, so its
# objects fall through to the bucket default above.
resource "aws_s3_bucket_policy" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonKmsEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.snapshots.arn}/*"
        # Null=false limits the deny to requests that send the header; a missing
        # key would otherwise satisfy StringNotEquals(IfExists) and block Elasticsearch.
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.snapshots.arn, "${aws_s3_bucket.snapshots.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  # Avoids a conflicting concurrent bucket config update with the public access block.
  depends_on = [aws_s3_bucket_public_access_block.snapshots]
}

# ECH nodes cannot assume an IAM role in our account, so the repository
# authenticates with an access key scoped to this bucket.
resource "aws_iam_user" "snapshots" {
  name = "${var.prefix}-es-snapshots"
}

resource "aws_iam_user_policy" "snapshots" {
  name = "s3-snapshot-repository"
  user = aws_iam_user.snapshots.name

  # Permissions from the Elasticsearch S3 repository docs.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:ListBucketVersions",
        ]
        Resource = aws_s3_bucket.snapshots.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.snapshots.arn}/*"
      },
      {
        # SSE-KMS: writes need a data key, reads need decrypt.
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.snapshots.arn
      },
    ]
  })
}

resource "aws_iam_access_key" "snapshots" {
  user = aws_iam_user.snapshots.name
}

resource "ec_deployment_elasticsearch_keystore" "s3_access_key" {
  deployment_id = var.deployment_id
  setting_name  = "s3.client.${local.s3_client}.access_key"
  value         = aws_iam_access_key.snapshots.id
}

resource "ec_deployment_elasticsearch_keystore" "s3_secret_key" {
  deployment_id = var.deployment_id
  setting_name  = "s3.client.${local.s3_client}.secret_key"
  value         = aws_iam_access_key.snapshots.secret
}

# -----------------------------------------------------------------------------
# Snapshot repository and ILM
# -----------------------------------------------------------------------------

resource "elasticstack_elasticsearch_snapshot_repository" "s3" {
  name = "demo-s3-repo"
  # ECH applies keystore changes asynchronously and new IAM keys take a few
  # seconds to propagate, so verifying at create time races and fails with
  # repository_verification_exception. The first ILM snapshot exercises it.
  verify = false

  s3 {
    bucket = aws_s3_bucket.snapshots.bucket
    client = local.s3_client
    # Set explicitly: elasticstack 0.16.6 leaves an unset endpoint unknown after
    # apply ("Provider returned invalid result object after apply").
    endpoint = "https://s3.${data.aws_region.current.region}.amazonaws.com"
  }

  # The client credentials must be in the keystore before the repository is verified.
  depends_on = [
    ec_deployment_elasticsearch_keystore.s3_access_key,
    ec_deployment_elasticsearch_keystore.s3_secret_key,
    aws_iam_user_policy.snapshots,
  ]
}

resource "elasticstack_elasticsearch_index_lifecycle" "demo" {
  name = var.ilm_policy_name

  hot {
    min_age = "0ms"
    rollover {
      max_age                = "7d"
      max_primary_shard_size = "50gb"
    }
  }

  frozen {
    min_age = var.frozen_min_age
    searchable_snapshot {
      snapshot_repository = elasticstack_elasticsearch_snapshot_repository.s3.name
    }
  }

  delete {
    min_age = var.delete_min_age
    delete {}
  }
}

# Every logs-*, metrics-* and traces-* index template (OTel, APM .1m, and the
# built-in fallbacks) composes <type>@custom, so setting the policy here covers
# all of them. Existing backing indices switch at their next rollover.
resource "elasticstack_elasticsearch_component_template" "custom" {
  for_each = toset(["logs", "metrics", "traces"])

  name = "${each.key}@custom"

  template {
    settings = jsonencode({
      index = {
        lifecycle = {
          name = elasticstack_elasticsearch_index_lifecycle.demo.name
        }
      }
    })
  }
}
