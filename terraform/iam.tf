# Instance roles are global. The SAME instance profiles are used by the primary instances and by the
# instances DRS recovers in the DR region (the DRS launch template points at them).

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  node_roles = toset(["web", "api", "db", "witness"])
  drs_roles  = var.install_drs_agent ? toset(["web", "api", "db"]) : toset([])
}

resource "aws_iam_role" "node" {
  for_each           = local.node_roles
  name               = "${var.name_prefix}-node-${each.value}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.node_roles
  role       = aws_iam_role.node[each.value].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  for_each   = local.node_roles
  role       = aws_iam_role.node[each.value].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Lets the DRS agent register and replicate using the instance role (no long-lived access keys).
resource "aws_iam_role_policy_attachment" "drs_agent" {
  for_each   = local.drs_roles
  role       = aws_iam_role.node[each.value].name
  policy_arn = var.drs_agent_policy_arn
}

locals {
  secret_arn_pattern = "arn:aws:secretsmanager:*:${local.account_id}:secret:${var.name_prefix}/*"
  common_statements = [
    # app bundle (first boot only), and /crp/* parameters (failover generation, private zone id)
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.artifacts.arn}/bundle/*" },
    { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"], Resource = "arn:aws:ssm:*:${local.account_id}:parameter/crp/*" },
  ]
  role_statements = {
    web     = []
    witness = []
    api = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = local.secret_arn_pattern },
      { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"], Resource = aws_route53_zone.internal_dr.arn },
    ]
    db = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = local.secret_arn_pattern },
      { Effect = "Allow", Action = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"], Resource = aws_route53_zone.internal_dr.arn },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.backups.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "${aws_s3_bucket.backups.arn}/*" },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.dr.arn },
    ]
  }
}

resource "aws_iam_role_policy" "node" {
  for_each = local.node_roles
  name     = "crp-node"
  role     = aws_iam_role.node[each.value].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.common_statements, local.role_statements[each.value])
  })
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.node_roles
  name     = "${var.name_prefix}-node-${each.value}"
  role     = aws_iam_role.node[each.value].name
}
