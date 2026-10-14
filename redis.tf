############################
# ElastiCache Redis (1 nodo, sin réplicas, en AZ A)
#
# Se usa aws_elasticache_replication_group (cluster mode disabled) con UN solo nodo
# en lugar de aws_elasticache_cluster porque este último NO permite activar cifrado
# en tránsito ni en reposo. El costo es el de un único nodo cache.t3.micro.
############################
resource "aws_elasticache_subnet_group" "redis" {
  name        = "${local.name_prefix}-redis-subnets"
  description = "Subnets privadas de ambas AZ para Redis"
  subnet_ids  = [for s in aws_subnet.private : s.id]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "Cache Redis de ${local.name_prefix} (1 nodo, AZ A)"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  port                 = var.redis_port
  parameter_group_name = var.redis_parameter_group_name

  # Un único nodo, sin réplicas ni failover (evita costo adicional).
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # El nodo se crea en AZ A -> misma AZ que la Lambda (subnet privada 10.0.11.0/24).
  # El subnet group incluye también la subnet privada de AZ B, pero no se usa.
  preferred_cache_cluster_azs = [local.azs.a]

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  # Sin acceso público (ElastiCache no tiene IP pública; solo existe en la VPC).
  # Cifrado en reposo y en tránsito (TLS); soportados por cache.t3.micro.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  # Sin persistencia: todas las claves son efímeras (TTL explícito desde la Lambda).
  snapshot_retention_limit = 0

  apply_immediately = true

  tags = { Name = "${local.name_prefix}-redis" }
}
