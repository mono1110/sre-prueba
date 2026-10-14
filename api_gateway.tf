############################
# HTTP API
############################
resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-http-api"
  description   = "API publica del servicio de procesamiento (POST /process)"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins     = var.api_cors_allow_origins
    allow_methods     = var.api_cors_allow_methods
    allow_headers     = var.api_cors_allow_headers
    expose_headers    = var.api_cors_expose_headers
    max_age           = 3600
    allow_credentials = false
  }
}

# Integración proxy con Lambda (payload format 2.0).
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.process_handler.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "process" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /process"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

############################
# Access logs (CloudWatch) - distintos de los logs de ejecución de la Lambda
############################
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-http-api-access"
  retention_in_days = var.api_log_retention_days
}

# Permiso explícito para que el servicio de entrega de logs escriba SOLO en este log group.
data "aws_iam_policy_document" "api_access_logs" {
  statement {
    sid       = "AllowApiGatewayLogDelivery"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api_access.arn}:log-stream:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "api_access" {
  policy_name     = "${local.name_prefix}-apigw-access-logs"
  policy_document = data.aws_iam_policy_document.api_access_logs.json
}

############################
# Stage con despliegue automático y throttling
############################
resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = var.api_stage_name
  auto_deploy = true

  # Throttling a nivel de stage (aplica a todas las rutas).
  default_route_settings {
    throttling_rate_limit  = var.api_throttling_rate_limit
    throttling_burst_limit = var.api_throttling_burst_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn

    format = jsonencode({
      requestId               = "$context.requestId"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      path                    = "$context.path"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      sourceIp                = "$context.identity.sourceIp"
      userAgent               = "$context.identity.userAgent"
      responseLength          = "$context.responseLength"
      responseLatencyMs       = "$context.responseLatency"
      integrationLatencyMs    = "$context.integration.latency"
      integrationStatus       = "$context.integration.status"
      integrationErrorMessage = "$context.integrationErrorMessage"
      errorMessage            = "$context.error.message"
    })
  }

  depends_on = [
    aws_apigatewayv2_route.process,
    aws_cloudwatch_log_resource_policy.api_access,
  ]
}
