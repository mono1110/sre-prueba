############################
# Rol de ejecución de Lambda
############################
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name_prefix}-lambda-role"
  description        = "Rol de ejecucion de la Lambda process_handler"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# 1) Política administrada: SOLO gestión de ENI para acceder a la VPC
#    (Create/Describe/DeleteNetworkInterface, etc.). No incluye permisos de logs.
resource "aws_iam_role_policy_attachment" "lambda_eni" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaENIManagementAccess"
}

# 2) Política propia: logs únicamente en el log group de esta función
#    (el log group lo crea Terraform, por eso no se concede CreateLogGroup).
data "aws_iam_policy_document" "lambda_logs" {
  statement {
    sid     = "WriteOwnLogGroup"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      aws_cloudwatch_log_group.lambda.arn,
      "${aws_cloudwatch_log_group.lambda.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_logs" {
  name   = "cloudwatch-logs-own-group"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_logs.json
}

# 3) Política propia: PutObject solo sobre <prefijo>/* del bucket de resultados.
data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid       = "PutResultsObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.results.arn}/${var.results_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "lambda_s3" {
  name   = "s3-put-results-prefix"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_s3.json
}
