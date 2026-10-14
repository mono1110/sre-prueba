############################
# Empaquetado automático de la Lambda
#
# `data "external"` ejecuta scripts/package_lambda.py durante el plan/apply:
#   1. instala requirements.txt (redis) en un directorio de staging, descargando
#      wheels para el runtime y la arquitectura de Lambda (pip --platform);
#   2. copia lambda/*.py y genera build/process_handler.zip de forma DETERMINISTA
#      (orden fijo, fechas fijas), de modo que el mismo input produce el mismo hash;
#   3. omite el trabajo si nada cambió (sello con el hash de las entradas);
#   4. devuelve la ruta y el SHA-256 (base64) REAL del ZIP.
#
# Por qué un data source y no null_resource/terraform_data:
#   - en un checkout limpio el ZIP no existe cuando Terraform planifica; con un
#     recurso solo se podría informar un hash "calculado" y no el del ZIP real;
#   - al ejecutarse antes de planificar, filename/source_code_hash apuntan siempre a
#     un archivo que ya existe y el primer `terraform apply` funciona sin pasos previos;
#   - la dependencia queda explícita: aws_lambda_function referencia el resultado.
# El hash cambia (y la función se actualiza) si cambia handler.py, requirements.txt,
# el script de empaquetado, el runtime o la arquitectura.
############################
locals {
  lambda_source_dir  = abspath("${path.module}/lambda")
  lambda_build_dir   = abspath("${path.module}/build")
  lambda_package_cli = abspath("${path.module}/scripts/package_lambda.py")
}

data "external" "lambda_package" {
  program = [var.python_executable, local.lambda_package_cli]

  query = {
    source_dir        = local.lambda_source_dir
    requirements_file = "${local.lambda_source_dir}/requirements.txt"
    build_dir         = local.lambda_build_dir
    python_version    = trimprefix(var.lambda_runtime, "python")
    architecture      = var.lambda_architecture
  }
}

############################
# Log group de la Lambda (creado por Terraform: retención controlada y permisos mínimos)
############################
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = var.lambda_log_retention_days
}

############################
# Función Lambda (en la subnet privada de AZ A únicamente)
############################
resource "aws_lambda_function" "process_handler" {
  function_name = local.lambda_function_name
  description   = "Procesa solicitudes con cache-aside sobre Redis y persiste resultados en S3"
  role          = aws_iam_role.lambda.arn

  runtime       = var.lambda_runtime
  architectures = [var.lambda_architecture]
  handler       = "handler.process_handler"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout_seconds

  filename         = data.external.lambda_package.result.zip_path
  source_code_hash = data.external.lambda_package.result.source_code_hash

  # Solo la subnet privada de AZ A (10.0.11.0/24): misma AZ que el nodo de Redis.
  vpc_config {
    subnet_ids         = [aws_subnet.private["a"].id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(
      {
        RESULTS_BUCKET            = aws_s3_bucket.results.id
        RESULTS_PREFIX            = var.results_prefix
        REDIS_HOST                = aws_elasticache_replication_group.redis.primary_endpoint_address
        REDIS_PORT                = tostring(var.redis_port)
        REDIS_TLS                 = "true"
        REDIS_VERIFY_TLS_HOSTNAME = tostring(var.redis_verify_tls_hostname)
        CACHE_TTL_SECONDS         = tostring(var.cache_ttl_seconds)
        LOG_LEVEL                 = var.lambda_log_level
        # Fuerza el endpoint regional de S3 (incluido us-east-1), que es el cubierto por
        # el Gateway Endpoint regional.
        AWS_S3_US_EAST_1_REGIONAL_ENDPOINT = "regional"
      },
      var.lambda_environment_overrides
    )
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.lambda.name
    application_log_level = var.lambda_log_level
    system_log_level      = "WARN"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_eni, # permisos de ENI antes de crear la función en VPC
    aws_iam_role_policy.lambda_logs,
    aws_iam_role_policy.lambda_s3,
    aws_cloudwatch_log_group.lambda,
    aws_vpc_endpoint.s3,
    aws_route.private_nat,
    aws_s3_bucket_policy.results,
  ]
}

############################
# Permiso para que API Gateway invoque la función (solo POST /process de esta API/stage)
############################
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/${var.api_stage_name}/POST/process"
}
