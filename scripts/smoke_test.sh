#!/usr/bin/env bash
# Pruebas de aceptación A-D contra la infraestructura YA desplegada.
# Guarda la evidencia en ./evidence/ (la que pide la prueba técnica).
#
# Requisitos: bash, curl, aws CLI con credenciales válidas, terraform (para leer outputs).
# Uso:
#   ./scripts/smoke_test.sh              # incluye la espera de 61 s de la Prueba C
#   SKIP_EXPIRY=1 ./scripts/smoke_test.sh   # omite la Prueba C
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/evidence}"
mkdir -p "$EVIDENCE_DIR"

API_URL="$(terraform output -raw process_url)"
BUCKET="$(terraform output -raw results_bucket_name)"
REGION="$(terraform output -raw aws_region)"
LAMBDA_LOG_GROUP="$(terraform output -raw lambda_log_group_name)"
TODAY="$(date -u +%F)"
RUN_ID="smoke-$(date -u +%Y%m%d%H%M%S)"
PAYLOAD="{\"id\":\"$RUN_ID\",\"message\":\"hola mundo\",\"n\":42}"
PAYLOAD_REORDERED="{\"n\":42,\"message\":\"hola mundo\",\"id\":\"$RUN_ID\"}"
FAILED=0
LAST_STATUS=""
LAST_XCACHE=""

request() { # <etiqueta> <payload> <archivo-evidencia>
  local label="$1" payload="$2" out="$EVIDENCE_DIR/$3" headers body
  headers="$(mktemp)"; body="$(mktemp)"
  LAST_STATUS="$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' -X POST "$API_URL" \
    -H 'Content-Type: application/json' --data "$payload")"
  LAST_XCACHE="$(tr -d '\r' < "$headers" | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
  {
    echo "# $label"
    echo "# $(date -u +%FT%TZ)  POST $API_URL"
    echo "# payload: $payload"
    echo
    tr -d '\r' < "$headers"
    echo
    cat "$body"
    echo
  } | tee "$out"
  rm -f "$headers" "$body"
}

expect() { # <descripcion> <actual> <esperado>
  if [[ "$2" == "$3" ]]; then echo ">>> OK    $1 ($2)"; else echo ">>> FALLO $1: esperado '$3', obtenido '$2'"; FAILED=1; fi
  echo
}

echo "=== Prueba A: primera llamada (MISS) ==="
request "Prueba A - cache MISS" "$PAYLOAD" "01_request_miss.txt"
expect "HTTP 200" "$LAST_STATUS" "200"
expect "X-Cache" "$LAST_XCACHE" "MISS"

echo "=== Objeto en S3 ==="
S3_KEY="results/$TODAY/$RUN_ID.json"
{ echo "# aws s3 ls s3://$BUCKET/results/$TODAY/ --region $REGION"; aws s3 ls "s3://$BUCKET/results/$TODAY/" --region "$REGION" | grep "$RUN_ID" || true; } | tee "$EVIDENCE_DIR/03_s3_ls.txt"
aws s3 cp "s3://$BUCKET/$S3_KEY" - --region "$REGION" | tee "$EVIDENCE_DIR/04_s3_object.json"; echo
echo

echo "=== Prueba B: misma solicitud (HIT), con propiedades en otro orden ==="
request "Prueba B - cache HIT (JSON con propiedades reordenadas)" "$PAYLOAD_REORDERED" "02_request_hit.txt"
expect "HTTP 200" "$LAST_STATUS" "200"
expect "X-Cache" "$LAST_XCACHE" "HIT"

if [[ "${SKIP_EXPIRY:-0}" != "1" ]]; then
  echo "=== Prueba C: esperando 61 s para que expire la caché ==="
  sleep 61
  request "Prueba C - expiración -> MISS" "$PAYLOAD" "05_request_after_expiry.txt"
  expect "X-Cache tras expirar" "$LAST_XCACHE" "MISS"
fi

echo "=== Prueba D: errores controlados ==="
request "Prueba D1 - JSON inválido" '{"id": ' "06_error_invalid_json.txt"
expect "HTTP 400 (JSON inválido)" "$LAST_STATUS" "400"
request "Prueba D2 - id peligroso" '{"id":"../etc/passwd"}' "07_error_invalid_id.txt"
expect "HTTP 400 (id inválido)" "$LAST_STATUS" "400"

echo "=== Logs recientes de la Lambda (últimos 10 min) ==="
aws logs tail "$LAMBDA_LOG_GROUP" --since 10m --region "$REGION" --format short 2>&1 | tee "$EVIDENCE_DIR/08_lambda_logs.txt" | tail -n 20 || true

echo
if [[ "$FAILED" -eq 0 ]]; then echo "Todas las comprobaciones pasaron. Evidencia en: $EVIDENCE_DIR"; else echo "Hubo comprobaciones fallidas."; exit 1; fi
