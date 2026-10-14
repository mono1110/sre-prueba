############################
# VPC e Internet Gateway
############################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # necesario para resolver el endpoint privado de Redis
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

############################
# Subnets (claves: a = AZ A, b = AZ B)
############################
resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = local.azs[each.key]
  map_public_ip_on_launch = false # nada se lanza aquí con IP pública automática

  tags = {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = local.azs[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

############################
# NAT Gateway (UNO SOLO, en la subnet pública de AZ A)
#
# Decisión de costo: un único NAT Gateway abarata el stack, pero la salida a
# Internet de AMBAS subnets privadas depende de la AZ A. Si AZ A cae, se pierde la
# salida a Internet (no el acceso a S3, que usa el Gateway Endpoint, ni a Redis).
############################
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  tags = { Name = "${local.name_prefix}-nat-a" }

  depends_on = [aws_internet_gateway.main]
}

############################
# Rutas públicas: 0.0.0.0/0 -> Internet Gateway
############################
resource "aws_route_table" "public" {
  for_each = aws_subnet.public

  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-public-rt-${each.key}" }
}

resource "aws_route" "public_internet" {
  for_each = aws_route_table.public

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public[each.key].id
}

############################
# Rutas privadas: una tabla por subnet, 0.0.0.0/0 -> NAT Gateway
############################
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-private-rt-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

############################
# VPC Gateway Endpoint para S3
# Añade a las tablas privadas una ruta (por prefix list) hacia S3: el tráfico a S3
# viaja por la red de AWS, sin pasar por el NAT Gateway ni por Internet.
# La política del endpoint (s3.tf) limita lo que se puede hacer a través de él.
############################
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]
  policy            = data.aws_iam_policy_document.s3_endpoint.json

  tags = { Name = "${local.name_prefix}-s3-gw-endpoint" }
}
