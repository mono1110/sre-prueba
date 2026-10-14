Diagrama de arquitectura:
El diagrama se encuentra en el archivo: Arquitectura.png

## 1. Prerrequisitos

### Herramientas

Antes de desplegar el stack, se deben instalar las siguientes herramientas:

| Herramienta | Versión / configuración                                             |
| ----------- | ------------------------------------------------------------------- |
| Terraform   | Versión 1.x compatible con la configuración del proyecto            |
| AWS CLI     | AWS CLI v2, autenticado con una cuenta de AWS                       |
| Python      | Python 3.12, utilizado para empaquetar y ejecutar la función Lambda |
| Git         | Recomendado para clonar el repositorio y controlar versiones        |
| curl        | Para probar el endpoint HTTP; también se puede utilizar Postman     |

El proyecto utiliza el proveedor `hashicorp/aws` con la versión instalada `5.100.0` y el proveedor `hashicorp/external` `2.4.2`. Las versiones de los proveedores se gestionan mediante `.terraform.lock.hcl`.

### Verificación de las herramientas

```powershell
terraform version
aws --version
python --version
git --version
curl.exe --version
```

### Configuración de AWS

La infraestructura se despliega en la región `us-east-1` (N. Virginia).

Se requiere:

- Una cuenta de AWS con permisos para crear y administrar los recursos definidos por Terraform.
- Credenciales configuradas mediante AWS CLI, un perfil de AWS o variables de entorno.
- Permisos para crear VPC, subredes, tablas de rutas, Internet Gateway, NAT Gateway, Elastic IP, security groups y VPC endpoints.
- Permisos para crear y administrar funciones Lambda, roles y políticas IAM, API Gateway, ElastiCache, S3 y grupos de logs de CloudWatch.
- Permisos para consultar los recursos y logs durante las pruebas.

Los permisos IAM deben ajustarse al principio de mínimo privilegio. No se recomienda utilizar credenciales de la cuenta root ni guardar claves de acceso directamente en los archivos `.tf` o `terraform.tfvars`.

Verificar la identidad de AWS antes de desplegar:

```powershell
aws sts get-caller-identity
aws configure list
```

El primer comando permite confirmar la cuenta y la identidad con la que se ejecutarán las operaciones.

## 2. Pasos exactos para desplegar desde cero

### Paso 1. Obtener el código fuente

Clonar el repositorio y entrar en la carpeta del proyecto. Si el código ya está descargado, basta con abrir PowerShell en el directorio raíz del proyecto.

```powershell
cd "$HOME\Documents\SUNDEVS_prueba_tecnica\sre-aws-terraform"
```

### Paso 2. Configurar las variables

Crear el archivo local de variables a partir de la plantilla incluida en el repositorio:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

Revisar `terraform.tfvars` y configurar los valores necesarios para el entorno, en particular:

- Región de AWS.
- Nombre o prefijo del entorno.
- Nombre del bucket de resultados, si se define como variable.
- Ruta del ejecutable de Python 3.12, si la configuración requiere una ruta local explícita.

En Windows, la ruta de Python puede tener un formato como:

```hcl
python_executable = "C:/Users/PC/AppData/Local/Programs/Python/Python312/python.exe"
```

Se debe utilizar la ruta real del equipo donde se ejecuta Terraform.

**Importante:** `terraform.tfvars` puede contener configuraciones específicas del equipo o del entorno. No se deben incluir claves secretas de AWS. Si la plantilla tiene otro nombre en el repositorio, utilizar el nombre real del archivo de ejemplo.

### Paso 3. Inicializar Terraform

```powershell
terraform init
```

Este comando descarga los proveedores requeridos e inicializa el directorio de trabajo. Se debe conservar `.terraform.lock.hcl` en el control de versiones para mantener consistencia entre despliegues.

### Paso 4. Validar y formatear la configuración

```powershell
terraform fmt -recursive
terraform validate
```

`terraform fmt` aplica el formato estándar de Terraform y `terraform validate` verifica la estructura y consistencia de la configuración.

### Paso 5. Revisar el plan de despliegue

```powershell
terraform plan
```

Antes de continuar, verificar los recursos que se van a crear y asegurarse de que el plan no incluya modificaciones o eliminaciones inesperadas.

### Paso 6. Desplegar la infraestructura

```powershell
terraform apply
```

Revisar el plan presentado por Terraform y confirmar con `yes` cuando se solicite.

Terraform creará los recursos declarados en el proyecto, incluidos la red, las subredes, el enrutamiento, el NAT Gateway, el endpoint de S3, los security groups, el bucket de resultados, los permisos IAM, la función Lambda, Redis, API Gateway y los recursos de logging.

El despliegue puede tardar varios minutos, especialmente por la creación del NAT Gateway y del clúster de ElastiCache.

### Paso 7. Consultar los outputs

```powershell
terraform output
```

Este comando permite consultar los valores publicados por la configuración, por ejemplo, la URL del API y el nombre del bucket, siempre que estén declarados como outputs.

Para consultar un output específico en formato plano:

```powershell
terraform output -raw api_url
```

Utilizar el nombre real del output declarado en el proyecto si es diferente.

## 3. Verificación end-to-end

El flujo que se debe comprobar es:

1. El cliente envía una solicitud HTTP POST a API Gateway.
2. API Gateway invoca la función Lambda.
3. Lambda procesa el JSON recibido y calcula la información de salida.
4. Lambda consulta Redis para determinar si el resultado ya está en caché.
5. Si no existe una entrada válida, procesa la solicitud y guarda el resultado en S3.
6. Lambda devuelve la respuesta HTTP con los encabezados de caché.

### 3.1. Enviar una solicitud

En PowerShell, definir la URL base obtenida mediante `terraform output`. En el entorno desplegado durante las pruebas, la URL base fue:

```powershell
$API_URL = "https://3cqe0en4gh.execute-api.us-east-1.amazonaws.com/v1"
```

Preparar el cuerpo JSON:

```powershell
$body = @{
    id = "test-001"
    data = @{
        mensaje = "prueba SRE"
    }
} | ConvertTo-Json -Depth 10 -Compress
```

Ejecutar la solicitud:

```powershell
curl.exe -i -X POST "$API_URL/process" `
  -H "Content-Type: application/json" `
  -d $body
```

Se espera una respuesta HTTP `200 OK` con un JSON que incluya campos como `id`, `output`, `processed_at`, `request_sha256` y `s3_key`, según la implementación de Lambda.

Ejemplo de respuesta observada durante las pruebas:

```json
{
  "id": "test-001",
  "output": {
    "reversed_strings": {},
    "top_level_fields": 2
  },
  "processed_at": "2026-10-14T03:23:53Z",
  "request_sha256": "00cfdc3a7e235b4249774866937f59a2afbdb2394e6b416eb9653f80d4aad7cb",
  "s3_key": "results/2026-10-14/test-001.json"
}
```

Los valores de fecha y hash variarán según la solicitud y el momento de ejecución.

### 3.2. Verificar la caché de Redis

Repetir exactamente la misma solicitud:

```powershell
curl.exe -i -X POST "$API_URL/process" `
  -H "Content-Type: application/json" `
  -d $body
```

Revisar los encabezados de respuesta:

- `X-Cache: MISS`: el resultado no estaba disponible en caché.
- `X-Cache: HIT`: el resultado se recuperó de la caché.
- `X-Cache-Ttl`: tiempo de vida restante informado por la implementación, si se incluye en la respuesta.

En las pruebas realizadas, la primera solicitud devolvió `MISS` y tardó aproximadamente 2,64 segundos; la segunda devolvió `HIT` y tardó aproximadamente 149 milisegundos. Estas mediciones corresponden a dos solicitudes concretas, no a una garantía de rendimiento.

Para comprobar la expiración, esperar más de 60 segundos desde que se almacena la entrada y volver a enviar la misma solicitud. Si no ha sido renovada y el comportamiento de expiración está implementado correctamente, se espera un nuevo `MISS`.

### 3.3. Verificar la persistencia en S3

Obtener el nombre real del bucket mediante:

```powershell
terraform output
```

Después, reemplazar `NOMBRE-DEL-BUCKET` por el valor obtenido:

```powershell
aws s3 ls s3://NOMBRE-DEL-BUCKET/results/2026-10-14/
```

Para consultar el contenido del resultado:

```powershell
aws s3 cp s3://NOMBRE-DEL-BUCKET/results/2026-10-14/test-001.json -
```

La fecha del prefijo debe coincidir con la fecha utilizada por la aplicación, que en el ejemplo de respuesta se expresó en UTC. Si se ejecuta la prueba otro día, se debe actualizar el prefijo correspondiente.

La existencia del objeto confirma que el resultado se persistió en S3. La respuesta HTTP por sí sola no sustituye esta verificación.

### 3.4. Verificar los logs de Lambda

Consultar los grupos de logs disponibles:

```powershell
aws logs describe-log-groups `
  --log-group-name-prefix "/aws/lambda/" `
  --query "logGroups[].logGroupName" `
  --output table
```

Identificar el nombre del grupo de logs de la función y consultar los eventos recientes:

```powershell
aws logs tail "/aws/lambda/NOMBRE-DE-LA-LAMBDA" --since 15m
```

Reemplazar `NOMBRE-DE-LA-LAMBDA` por el nombre real de la función desplegada.

También se pueden revisar los logs de acceso de API Gateway si están habilitados y configurados en la infraestructura.

### 3.5. Criterios de aceptación

- [ ] API Gateway recibe el POST y devuelve HTTP 200 para una solicitud válida.
- [ ] La respuesta contiene los campos esperados.
- [ ] La primera solicitud devuelve `X-Cache: MISS`.
- [ ] Una solicitud repetida devuelve `X-Cache: HIT`.
- [ ] El resultado se encuentra en la ruta correspondiente del bucket S3.
- [ ] Los logs de CloudWatch permiten consultar la ejecución.
- [ ] Los recursos privados no necesitan exponerse públicamente para que el flujo funcione.

## 4. Decisiones de diseño relevantes

### API Gateway: HTTP API frente a REST API

Se eligió **API Gateway HTTP API** porque ofrece una integración directa con Lambda, admite CORS y permite construir el endpoint requerido con una configuración más sencilla y generalmente menos costosa que REST API.

REST API sería una alternativa si se necesitaran características adicionales específicas de ese producto. Para el alcance de esta prueba, HTTP API resulta suficiente.

### Redis: ElastiCache `cache.t3.micro`

Se utiliza un nodo de ElastiCache Redis con tipo `cache.t3.micro` y motor Redis 7.1, adecuado para demostrar el patrón de caché con un costo relativamente bajo frente a nodos de mayor capacidad.

La caché utiliza un TTL de 60 segundos. De esta manera, las solicitudes repetidas pueden reutilizar un resultado reciente en lugar de ejecutar nuevamente todo el procesamiento.

Este tipo de nodo está orientado a cargas pequeñas y de prueba; no implica por sí solo alta disponibilidad ni capacidad de producción. La configuración de un único nodo tampoco proporciona la misma resiliencia que una arquitectura con réplicas y failover.

### Red: subredes públicas y privadas

Se utiliza una VPC con CIDR `10.0.0.0/16`, distribuida en dos zonas de disponibilidad de la región seleccionada:

| Tipo     | Subredes                       |
| -------- | ------------------------------ |
| Públicas | `10.0.1.0/24`, `10.0.2.0/24`   |
| Privadas | `10.0.11.0/24`, `10.0.12.0/24` |

Las subredes públicas tienen una ruta hacia Internet Gateway. El NAT Gateway permite que los recursos de las subredes privadas inicien conexiones salientes a Internet sin asignarles direcciones públicas.

La función Lambda está conectada a la red privada, mientras que Redis permanece accesible solamente desde la red autorizada por los security groups.

**Consideración de costo y disponibilidad:** el NAT Gateway tiene un costo asociado incluso cuando el tráfico es reducido. Además, la configuración desplegada no equivale a una arquitectura multi-AZ de alta disponibilidad para todos los componentes.

### S3 Gateway VPC Endpoint

Se utiliza un endpoint de tipo Gateway para S3 asociado a las tablas de rutas privadas. Esto permite que el tráfico destinado a S3 utilice la conectividad privada de AWS, sin tener que salir a través del NAT Gateway.

La configuración reduce el tráfico de S3 que pasaría por el NAT y ayuda a mantener el acceso al almacenamiento separado del acceso general a Internet.

### Seguridad de S3

El bucket de resultados mantiene habilitados los controles de bloqueo de acceso público, el cifrado y el versionado.

La política del bucket debe restringir las operaciones permitidas al rol de ejecución de Lambda y a los recursos que realmente necesiten acceder a los objetos.

La opción `s3_force_destroy = true`, si está habilitada en las variables del proyecto, permite que Terraform elimine el bucket incluso cuando contiene objetos. Es útil para limpiar un entorno de pruebas, pero debe revisarse antes de utilizarlo en un entorno con datos que deban conservarse.

### IAM y security groups

Se separan los permisos de la función Lambda de los controles de red:

- IAM determina qué acciones de AWS puede ejecutar la función.
- Los security groups determinan qué conexiones de red están permitidas.
- Redis no necesita exponerse directamente a Internet.
- La función necesita permisos suficientes para escribir los resultados en S3 y publicar logs en CloudWatch.

Este enfoque permite restringir tanto las acciones de la aplicación como sus conexiones de red.

### Observabilidad y control de tráfico

Se habilitan logs para apoyar la depuración y la revisión de las solicitudes. La retención configurada para los logs es de 14 días.

El stage `v1` tiene límites de throttling configurados con una tasa de 50 solicitudes por segundo y un burst de 100, de acuerdo con la configuración del proyecto. Estos límites ayudan a controlar picos de tráfico, pero no reemplazan una estrategia completa de protección contra abuso ni garantizan una capacidad sostenida exacta.

### Infraestructura como código

Terraform administra la creación y configuración de los recursos. Esto permite reproducir el despliegue, revisar los cambios mediante `terraform plan` y mantener la infraestructura versionada.

No se requiere crear manualmente los recursos en la consola de AWS para completar el despliegue descrito.

## 5. Limpieza del entorno de pruebas

Una vez terminadas las pruebas, se puede eliminar la infraestructura administrada por Terraform:

```powershell
terraform destroy
```

Revisar cuidadosamente el plan antes de confirmar.

La eliminación del entorno también puede borrar los resultados almacenados en S3 si el bucket está configurado para permitir su destrucción con contenido. No ejecutar este comando si se deben conservar los objetos o la infraestructura.
