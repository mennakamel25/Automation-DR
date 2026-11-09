# ---------------------------------------------------------------- KMS + backup bucket (DR region)
# The pgBackRest repository lives in the DR region on purpose: it must survive the loss of the primary
# region and it is the fallback if a DRS recovery ever fails.
resource "aws_kms_key" "dr" {
  provider                = aws.dr
  description             = "${var.name_prefix} database backups"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "dr" {
  provider      = aws.dr
  name          = "alias/${var.name_prefix}-backups"
  target_key_id = aws_kms_key.dr.key_id
}

resource "aws_s3_bucket" "backups" {
  provider            = aws.dr
  bucket              = "${var.name_prefix}-backups-${local.account_id}-${var.dr_region}"
  object_lock_enabled = true
  force_destroy       = false
}

resource "aws_s3_bucket_versioning" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.dr.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  provider                = aws.dr
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_object_lock_configuration" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 35
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  depends_on = [aws_s3_bucket_versioning.backups]
}

resource "aws_s3_bucket_policy" "backups_tls_only" {
  provider = aws.dr
  bucket   = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------- application bundle (primary region)
# EC2 user data is limited to 16 KB, so the app bundle is staged in S3 and pulled at first boot.
data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.module}/../application"
  output_path = "${path.module}/.build/app.zip"
  excludes    = ["backend/tests", "backend/pytest.ini", "backend/.venv", "backend/.pytest_cache", "backend/app/__pycache__"]
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-artifacts-${local.account_id}-${var.primary_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "bundle" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "bundle/app-${data.archive_file.app.output_md5}.zip"
  source = data.archive_file.app.output_path
  etag   = data.archive_file.app.output_md5
}

# ---------------------------------------------------------------- CloudTrail (audit of failover/failback), DR region
resource "aws_s3_bucket" "trail" {
  provider      = aws.dr
  count         = var.enable_cloudtrail ? 1 : 0
  bucket        = "${var.name_prefix}-trail-${local.account_id}-${var.dr_region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  provider                = aws.dr
  count                   = var.enable_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "trail" {
  provider = aws.dr
  count    = var.enable_cloudtrail ? 1 : 0
  bucket   = aws_s3_bucket.trail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AclCheck", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.trail[0].arn },
      { Sid = "Write", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.account_id}/*", Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } } },
    ]
  })
}

resource "aws_cloudtrail" "this" {
  provider                      = aws.dr
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.trail]
}
