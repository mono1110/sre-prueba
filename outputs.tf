output "process_url" {
  description = "URL invocable de POST /process."
  value       = "${trimsuffix(aws_apigatewayv2_stage.main.invoke_url, "/")}/process"
}

output "api_base_url" {
  description = "URL base del stage de la HTTP API."
  value       = aws_apigatewayv2_stage.main.invoke_url
}

output "aws_region" {
  description = "Región de despliegue."
  value       = var.aws_region
}

output "results_bucket_name" {
  description = "Bucket S3 con los resultados (prefijo results/<fecha>/<id>.json)."
  value       = aws_s3_bucket.results.id
}

output "lambda_function_name" {
  description = "Nombre de la función Lambda."
  value       = aws_lambda_function.process_handler.function_name
}

output "lambda_log_group_name" {
  description = "Log group de ejecución de la Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "api_access_log_group_name" {
  description = "Log group de access logs de API Gateway."
  value       = aws_cloudwatch_log_group.api_access.name
}

output "redis_primary_endpoint" {
  description = "Endpoint privado de Redis (no es un secreto; solo resoluble/alcanzable desde la VPC)."
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "AZ utilizadas (a = Lambda + Redis + NAT)."
  value       = local.azs
}

output "lambda_package_sha256_base64" {
  description = "SHA-256 (base64) del ZIP desplegado; cambia si cambian el código o las dependencias."
  value       = data.external.lambda_package.result.source_code_hash
}
