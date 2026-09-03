data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  ssm_parameter_arn_prefix = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}"
}

# ---------------------------------------------------------------------------
# Runner role
#
# This role grants no database access at all. Flyway authenticates with a
# username and password. The role exists so a human can open a shell through
# Session Manager without port 22, and so the instance can read the connection
# parameters it needs at boot.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "runner" {
  name               = "${local.name_prefix}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# AmazonSSMManagedInstanceCore and nothing broader: it covers agent registration
# and session establishment, and grants no access to S3, RDS or any other
# service. Who may open a session is then controlled by IAM on the human's user,
# and every session is recorded in CloudTrail.
resource "aws_iam_role_policy_attachment" "runner_ssm_core" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_parameters" {
  statement {
    sid    = "ReadProjectParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    # Scoped by ARN to this project's path only. The runner may read the
    # connection details for all three environments because it is the host that
    # runs migrations against all three.
    resources = [
      "${local.ssm_parameter_arn_prefix}/*",
    ]
  }

  statement {
    sid    = "DecryptSecureStringParameters"
    effect = "Allow"

    actions = ["kms:Decrypt"]

    # SecureString parameters here use the AWS managed key alias/aws/ssm, whose
    # key ID is account-specific and therefore cannot be written literally. The
    # ViaService condition is what actually constrains this: the key may only be
    # used through Parameter Store, never directly.
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "runner_parameters" {
  name   = "${local.name_prefix}-runner-parameter-read"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_parameters.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.name_prefix}-runner-profile"
  role = aws_iam_role.runner.name
}

# ---------------------------------------------------------------------------
# MySQL host role
#
# A separate role, not the runner's. The runner may read production credentials;
# a dev database host must not. Sharing one role would collapse two very
# different blast radii into one.
#
# Both the dev and test hosts use this role, so its path scope covers those two
# environments and deliberately excludes production.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "mysql" {
  name               = "${local.name_prefix}-mysql-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "mysql_ssm_core" {
  role       = aws_iam_role.mysql.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "mysql_parameters" {
  statement {
    sid    = "ReadNonProductionParameters"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      "${local.ssm_parameter_arn_prefix}/dev/*",
      "${local.ssm_parameter_arn_prefix}/test/*",
    ]
  }

  statement {
    sid    = "DecryptSecureStringParameters"
    effect = "Allow"

    actions   = ["kms:Decrypt"]
    resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "mysql_parameters" {
  name   = "${local.name_prefix}-mysql-parameter-read"
  role   = aws_iam_role.mysql.id
  policy = data.aws_iam_policy_document.mysql_parameters.json
}

resource "aws_iam_instance_profile" "mysql" {
  name = "${local.name_prefix}-mysql-profile"
  role = aws_iam_role.mysql.name
}
