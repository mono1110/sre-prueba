# Datos de cuenta/región y valores derivados compartidos por varios archivos.

data "aws_caller_identity" "current" {}

# Solo AZ disponibles y sin opt-in (excluye Local Zones / Wavelength).
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Mismos identificadores de AZ en TODOS los recursos (subnets, Redis, Lambda).
  # a -> primera AZ disponible, b -> segunda AZ disponible.
  azs = {
    a = data.aws_availability_zones.available.names[0]
    b = data.aws_availability_zones.available.names[1]
  }

  # Nombre global único: prefijo + cuenta + región (determinista, sin proveedor random).
  bucket_name = "${local.name_prefix}-results-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  lambda_function_name = "${local.name_prefix}-process-handler"
}
