############################
# Security Groups
############################

# Se vacía el SG "default" de la VPC (sin reglas) para que nada lo use por accidente.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-default-sg-locked" }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "SG de la Lambda process_handler (sin reglas de entrada)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-lambda-sg" }
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "SG de ElastiCache Redis: solo acepta trafico de la Lambda"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-redis-sg" }
}

# Terraform elimina la regla "allow all" de salida que AWS crea por defecto, de modo
# que solo existen las reglas declaradas a continuación.

# --- Redis: entrada exclusivamente desde el SG de Lambda en TCP 6379 ---
resource "aws_vpc_security_group_ingress_rule" "redis_from_lambda" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = var.redis_port
  to_port                      = var.redis_port
  description                  = "Redis desde el SG de Lambda"
}

# --- Lambda: salida mínima ---
resource "aws_vpc_security_group_egress_rule" "lambda_to_redis" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.redis.id
  ip_protocol                  = "tcp"
  from_port                    = var.redis_port
  to_port                      = var.redis_port
  description                  = "Lambda hacia Redis"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Lambda hacia S3 via Gateway Endpoint (prefix list de S3)"
}

# Salida HTTPS general (opcional): permite llamadas a APIs externas a través del NAT
# Gateway. Es la única regla amplia; se limita al puerto 443 y puede desactivarse con
# lambda_allow_internet_https_egress = false (la función actual no la necesita).
resource "aws_vpc_security_group_egress_rule" "lambda_https_internet" {
  count = var.lambda_allow_internet_https_egress ? 1 : 0

  security_group_id = aws_security_group.lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS saliente via NAT Gateway (llamadas a servicios externos)"
}
