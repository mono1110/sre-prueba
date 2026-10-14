############################
# Bucket de resultados
############################
resource "aws_s3_bucket" "results" {
  bucket        = local.bucket_name # único globalmente: prefijo + cuenta + región
  force_destroy = var.s3_force_destroy

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_ownership_controls" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    object_ownership = "BucketOwnerEnforced" # desactiva ACLs
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado por defecto con SSE-S3 (AES256): sin claves KMS que administrar ni permisos
# kms:* adicionales para el rol de Lambda.
resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Evita que el versionado acumule versiones antiguas indefinidamente.
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.s3_noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.results]
}

############################
# Bucket policy
#
# Solo hay permisos "Allow" para el rol de Lambda: PutObject sobre <prefijo>/* y
# únicamente a través del VPC Gateway Endpoint. No se concede nada a "*".
# Las identidades administrativas de la cuenta se rigen por sus propias políticas IAM;
# no se añade un "Deny a todos" por defecto para no bloquear a Terraform (ver
# s3_admin_principal_arns para activarlo de forma opcional).
############################
data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.results.arn,
      "${aws_s3_bucket.results.arn}/*",
    ]

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

  statement {
    sid       = "AllowLambdaPutResultsViaVpcEndpoint"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.results.arn}/${var.results_prefix}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.lambda.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
  }

  # Cualquier acceso del rol de Lambda que NO venga del Gateway Endpoint se deniega.
  statement {
    sid     = "DenyLambdaRoleOutsideVpcEndpoint"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.results.arn,
      "${aws_s3_bucket.results.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.lambda.arn]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [aws_vpc_endpoint.s3.id]
    }
  }

  # OPCIONAL: "solo el rol de Lambda (y los administradores indicados)".
  dynamic "statement" {
    for_each = length(var.s3_admin_principal_arns) > 0 ? [1] : []

    content {
      sid     = "DenyEveryoneExceptLambdaAndAdmins"
      effect  = "Deny"
      actions = ["s3:*"]
      resources = [
        aws_s3_bucket.results.arn,
        "${aws_s3_bucket.results.arn}/*",
      ]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "ArnNotLike"
        variable = "aws:PrincipalArn"
        values   = concat([aws_iam_role.lambda.arn], var.s3_admin_principal_arns)
      }
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.results.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.results]
}

############################
# Política del VPC Gateway Endpoint
# Limita lo que puede hacerse con S3 desde la VPC a lo estrictamente necesario:
# PutObject sobre <prefijo>/* de ESTE bucket. (Terraform y la CLI se ejecutan fuera
# de la VPC, por lo que no se ven afectados.)
############################
data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "AllowPutResultsOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.results.arn}/${var.results_prefix}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}
