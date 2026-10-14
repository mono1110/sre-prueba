# Versiones de Terraform y proveedores.
# - Backend: local (por defecto). El estado queda en ./terraform.tfstate (ignorado por Git).
# - El archivo .terraform.lock.hcl se genera con `terraform init`; se recomienda versionarlo.
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70" # >= 5.70, < 6.0
    }

    # Se usa únicamente para ejecutar el script de empaquetado de la Lambda
    # durante el plan (ver lambda.tf para la justificación).
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
