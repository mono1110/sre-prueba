############################
# General
############################
variable "aws_region" {
  description = "Región de AWS donde se despliega la infraestructura."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo corto (minúsculas, números y guiones) para nombrar los recursos."
  type        = string
  default     = "sre-challenge"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.project_name))
    error_message = "project_name debe tener 2-20 caracteres, empezar por letra y usar solo minúsculas, números y guiones."
  }
}

variable "environment" {
  description = "Nombre del entorno (dev, test, prod...)."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.environment))
    error_message = "environment debe tener 2-10 caracteres alfanuméricos en minúsculas."
  }
}

variable "tags" {
  description = "Etiquetas adicionales aplicadas a todos los recursos."
  type        = map(string)
  default     = {}
}

############################
# Red
############################
variable "vpc_cidr" {
  description = "CIDR de la VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr debe ser un CIDR IPv4 válido."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR de las subnets públicas. Claves obligatorias: a (AZ A) y b (AZ B)."
  type        = map(string)
  default = {
    a = "10.0.1.0/24"
    b = "10.0.2.0/24"
  }

  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for k in ["a", "b"] : contains(keys(var.public_subnet_cidrs), k)])
    error_message = "public_subnet_cidrs debe definir exactamente las claves 'a' y 'b'."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR de las subnets privadas. Claves obligatorias: a (AZ A) y b (AZ B)."
  type        = map(string)
  default = {
    a = "10.0.11.0/24"
    b = "10.0.12.0/24"
  }

  validation {
    condition     = length(var.private_subnet_cidrs) == 2 && alltrue([for k in ["a", "b"] : contains(keys(var.private_subnet_cidrs), k)])
    error_message = "private_subnet_cidrs debe definir exactamente las claves 'a' y 'b'."
  }
}

############################
# Lambda
############################
variable "lambda_runtime" {
  description = "Runtime de Lambda (Python). También determina la versión de Python usada para empaquetar dependencias."
  type        = string
  default     = "python3.12"

  validation {
    condition     = can(regex("^python3\\.[0-9]+$", var.lambda_runtime))
    error_message = "lambda_runtime debe tener el formato python3.X (por ejemplo, python3.12)."
  }
}

variable "lambda_architecture" {
  description = "Arquitectura de la Lambda: x86_64 o arm64. Se usa también para descargar wheels compatibles."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.lambda_architecture)
    error_message = "lambda_architecture debe ser x86_64 o arm64."
  }
}

variable "lambda_memory_size" {
  description = "Memoria de la Lambda en MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Timeout de la Lambda en segundos (API Gateway HTTP API corta a los 30 s)."
  type        = number
  default     = 10

  validation {
    condition     = var.lambda_timeout_seconds >= 3 && var.lambda_timeout_seconds <= 29
    error_message = "lambda_timeout_seconds debe estar entre 3 y 29 (límite de integración de HTTP API: 30 s)."
  }
}

variable "lambda_log_level" {
  description = "Nivel de log de la aplicación (DEBUG, INFO, WARN, ERROR)."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARN", "ERROR"], var.lambda_log_level)
    error_message = "lambda_log_level debe ser DEBUG, INFO, WARN o ERROR."
  }
}

variable "lambda_allow_internet_https_egress" {
  description = "Si es true, el SG de Lambda permite salida TCP 443 a 0.0.0.0/0 (vía NAT Gateway) para futuras llamadas a APIs externas. Poner false para el endurecimiento máximo: la función actual solo necesita Redis y S3."
  type        = bool
  default     = true
}

variable "lambda_environment_overrides" {
  description = "Variables de entorno adicionales/sobrescritas en la Lambda. Útil para pruebas de fallo controladas (ver README, Prueba D). Dejar vacío en uso normal."
  type        = map(string)
  default     = {}
}

variable "python_executable" {
  description = "Intérprete de Python usado en la máquina local para empaquetar la Lambda (en Windows suele ser 'python')."
  type        = string
  default     = "python3"
}

############################
# Caché / Redis
############################
variable "cache_ttl_seconds" {
  description = "TTL explícito (segundos) de las claves en Redis."
  type        = number
  default     = 60

  validation {
    condition     = var.cache_ttl_seconds >= 1 && var.cache_ttl_seconds <= 86400
    error_message = "cache_ttl_seconds debe estar entre 1 y 86400."
  }
}

variable "redis_node_type" {
  description = "Tipo de nodo de ElastiCache."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Versión de Redis OSS en ElastiCache."
  type        = string
  default     = "7.1"
}

variable "redis_parameter_group_name" {
  description = "Parameter group de ElastiCache compatible con redis_engine_version."
  type        = string
  default     = "default.redis7"
}

variable "redis_port" {
  description = "Puerto TCP de Redis."
  type        = number
  default     = 6379
}

variable "redis_verify_tls_hostname" {
  description = "Si es true, el cliente Redis valida que el certificado TLS coincida con el hostname del endpoint."
  type        = bool
  default     = true
}

############################
# S3
############################
variable "results_prefix" {
  description = "Prefijo de S3 donde se guardan los resultados (results/<fecha>/<id>.json)."
  type        = string
  default     = "results"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,31}$", var.results_prefix))
    error_message = "results_prefix debe ser un segmento simple (minúsculas, números, guiones), sin barras."
  }
}

variable "s3_force_destroy" {
  description = "Si es true, `terraform destroy` vacía el bucket (incluidas versiones) antes de borrarlo. Cómodo para una prueba; poner false en producción."
  type        = bool
  default     = true
}

variable "s3_noncurrent_version_retention_days" {
  description = "Días que se conservan las versiones no vigentes de los objetos antes de expirar."
  type        = number
  default     = 30
}

variable "s3_admin_principal_arns" {
  description = "OPCIONAL. Si se informa, la bucket policy añade un Deny para cualquier principal que no sea el rol de Lambda ni uno de estos ARN (admite comodines). Déjalo vacío salvo que sepas el ARN exacto de tu identidad: un valor incorrecto te bloquea el acceso (incluido Terraform)."
  type        = list(string)
  default     = []
}

############################
# API Gateway
############################
variable "api_stage_name" {
  description = "Nombre del stage de la HTTP API."
  type        = string
  default     = "v1"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.api_stage_name))
    error_message = "api_stage_name solo admite letras, números, guiones y guiones bajos."
  }
}

variable "api_throttling_rate_limit" {
  description = "Límite sostenido de peticiones por segundo del stage."
  type        = number
  default     = 50

  validation {
    condition     = var.api_throttling_rate_limit >= 1
    error_message = "api_throttling_rate_limit debe ser >= 1."
  }
}

variable "api_throttling_burst_limit" {
  description = "Límite de ráfaga (burst) del stage."
  type        = number
  default     = 100

  validation {
    condition     = var.api_throttling_burst_limit >= 1
    error_message = "api_throttling_burst_limit debe ser >= 1."
  }
}

variable "api_cors_allow_origins" {
  description = "Orígenes permitidos por CORS. [\"*\"] = cualquier origen."
  type        = list(string)
  default     = ["*"]
}

variable "api_cors_allow_methods" {
  description = "Métodos HTTP permitidos por CORS."
  type        = list(string)
  default     = ["POST", "OPTIONS"]
}

variable "api_cors_allow_headers" {
  description = "Encabezados de petición permitidos por CORS."
  type        = list(string)
  default     = ["content-type", "authorization", "x-requested-with"]
}

variable "api_cors_expose_headers" {
  description = "Encabezados de respuesta visibles para JavaScript en el navegador (necesario para leer X-Cache)."
  type        = list(string)
  default     = ["x-cache", "x-cache-ttl"]
}

############################
# CloudWatch
############################
variable "lambda_log_retention_days" {
  description = "Retención (días) del log group de la Lambda."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.lambda_log_retention_days)
    error_message = "Valor de retención no soportado por CloudWatch Logs."
  }
}

variable "api_log_retention_days" {
  description = "Retención (días) del log group de access logs de API Gateway."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.api_log_retention_days)
    error_message = "Valor de retención no soportado por CloudWatch Logs."
  }
}
