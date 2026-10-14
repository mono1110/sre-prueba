"""Lambda `process_handler`: patrón cache-aside sobre Redis con persistencia en S3.

Flujo (API Gateway HTTP API, payload format 2.0):
    1. Lee y valida el cuerpo JSON (debe ser un objeto).
    2. Calcula una clave de caché determinista: SHA-256 del JSON canónico
       (claves ordenadas, sin espacios), por lo que el orden de las propiedades
       no cambia la clave.
    3. Consulta Redis:
         HIT  -> devuelve el resultado cacheado sin reprocesar (X-Cache: HIT).
         MISS -> procesa, guarda en S3 (results/<YYYY-MM-DD>/<id>.json), guarda en
                 Redis con TTL explícito (SET ... EX) y responde (X-Cache: MISS).

Manejo de errores (nunca se oculta un fallo devolviendo 200):
    400 / 413  solicitud inválida (JSON mal formado, id no válido, cuerpo demasiado grande)
    500        fallo de dependencia (Redis, S3) o error inesperado.
    El cuerpo del error es descriptivo pero genérico; el detalle técnico solo va a
    CloudWatch. Nunca se registran el cuerpo de la solicitud ni secretos.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Any

import boto3
import redis
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from redis.backoff import ExponentialBackoff
from redis.exceptions import ConnectionError as RedisConnectionError
from redis.exceptions import RedisError
from redis.exceptions import TimeoutError as RedisTimeoutError
from redis.retry import Retry

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# --------------------------------------------------------------------------- #
# Configuración (inyectada por Terraform mediante variables de entorno)
# --------------------------------------------------------------------------- #
RESULTS_BUCKET = os.environ.get("RESULTS_BUCKET", "")
RESULTS_PREFIX = os.environ.get("RESULTS_PREFIX", "results").strip("/")
REDIS_HOST = os.environ.get("REDIS_HOST", "")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_TLS = os.environ.get("REDIS_TLS", "true").lower() == "true"
REDIS_VERIFY_TLS_HOSTNAME = os.environ.get("REDIS_VERIFY_TLS_HOSTNAME", "true").lower() == "true"
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "60"))
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", str(256 * 1024)))

CACHE_KEY_PREFIX = "process:v1:"
# El id forma parte de la clave de S3: se restringe a un conjunto seguro de caracteres.
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class ApiError(Exception):
    """Error controlado que se traduce en una respuesta HTTP con cuerpo JSON."""

    def __init__(self, status_code: int, error: str, message: str, cache_state: str | None = None):
        super().__init__(message)
        self.status_code = status_code
        self.error = error
        self.message = message
        # "MISS" si el error ocurre después de haber determinado que no había caché.
        self.cache_state = cache_state


# --------------------------------------------------------------------------- #
# Clientes (se crean una vez por entorno de ejecución y se reutilizan)
# --------------------------------------------------------------------------- #
_redis_client: redis.Redis | None = None
_s3_client: Any = None


def get_redis() -> redis.Redis:
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            ssl=REDIS_TLS,  # cifrado en tránsito habilitado en ElastiCache
            ssl_cert_reqs="required",
            ssl_check_hostname=REDIS_VERIFY_TLS_HOSTNAME,
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
            health_check_interval=30,
            retry=Retry(ExponentialBackoff(cap=0.5, base=0.05), 1),
            retry_on_error=[RedisConnectionError, RedisTimeoutError],
        )
    return _redis_client


def get_s3() -> Any:
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client(
            "s3",
            region_name=os.environ.get("AWS_REGION"),
            config=Config(
                connect_timeout=3,
                read_timeout=5,
                retries={"max_attempts": 2, "mode": "standard"},
            ),
        )
    return _s3_client


# --------------------------------------------------------------------------- #
# Validación y derivación de claves
# --------------------------------------------------------------------------- #
def _reject_json_constant(value: str) -> None:
    raise ValueError(f"constante JSON no permitida: {value}")


def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    """Obtiene el cuerpo JSON (objeto) de un evento de HTTP API v2.0."""
    raw = event.get("body")
    if raw is None or raw == "":
        raise ApiError(400, "empty_body", "El cuerpo de la solicitud es obligatorio y debe ser un objeto JSON.")

    try:
        raw_bytes = base64.b64decode(raw, validate=True) if event.get("isBase64Encoded") else raw.encode("utf-8")
        text = raw_bytes.decode("utf-8")
    except (binascii.Error, ValueError, UnicodeError):
        raise ApiError(400, "invalid_body_encoding", "El cuerpo de la solicitud no tiene una codificación válida (UTF-8).")

    if len(raw_bytes) > MAX_BODY_BYTES:
        raise ApiError(413, "payload_too_large", f"El cuerpo supera el máximo permitido de {MAX_BODY_BYTES} bytes.")

    try:
        payload = json.loads(text, parse_constant=_reject_json_constant)
    except (ValueError, RecursionError):
        raise ApiError(400, "invalid_json", "El cuerpo de la solicitud no es un JSON válido.")

    if not isinstance(payload, dict):
        raise ApiError(400, "invalid_body_type", "El cuerpo debe ser un objeto JSON (por ejemplo, {\"clave\": \"valor\"}).")
    return payload


def canonical_json(payload: dict[str, Any]) -> str:
    """JSON canónico: claves ordenadas recursivamente y sin espacios."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def resolve_result_id(payload: dict[str, Any], digest: str) -> str:
    """`id` del cliente (validado) o, si falta, un hash determinista del contenido."""
    if "id" not in payload:
        return digest[:32]
    value = payload["id"]
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ApiError(400, "invalid_id", "El campo 'id' debe ser una cadena o un entero.")
    candidate = str(value)
    if not ID_PATTERN.fullmatch(candidate):
        raise ApiError(
            400,
            "invalid_id",
            "El campo 'id' debe tener 1-128 caracteres [A-Za-z0-9._-] y empezar por letra o número.",
        )
    return candidate


# --------------------------------------------------------------------------- #
# Lógica de negocio de ejemplo
# --------------------------------------------------------------------------- #
def process_payload(
    payload: dict[str, Any], digest: str, result_id: str, s3_key: str, now: datetime
) -> dict[str, Any]:
    """Transformación simple y reproducible: invierte los strings de primer nivel."""
    reversed_strings = {
        key: value[::-1]
        for key, value in sorted(payload.items())
        if key != "id" and isinstance(value, str)
    }
    return {
        "id": result_id,
        "request_sha256": digest,
        "processed_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "s3_key": s3_key,
        "output": {
            "top_level_fields": len(payload),
            "reversed_strings": reversed_strings,
        },
    }


# --------------------------------------------------------------------------- #
# Acceso a dependencias (cada fallo se convierte en ApiError y se registra)
# --------------------------------------------------------------------------- #
def read_cache(cache_key: str) -> tuple[str | None, int | None]:
    try:
        pipe = get_redis().pipeline(transaction=False)
        pipe.get(cache_key)
        pipe.ttl(cache_key)
        value, ttl = pipe.execute()
    except RedisError as exc:
        logger.exception(
            "Fallo al consultar Redis",
            extra={"error_code": "cache_unavailable", "error_type": type(exc).__name__},
        )
        raise ApiError(500, "cache_unavailable", "No se pudo consultar la caché (Redis). Intente de nuevo más tarde.") from exc
    return value, ttl


def write_s3(s3_key: str, body: str) -> None:
    try:
        get_s3().put_object(
            Bucket=RESULTS_BUCKET,
            Key=s3_key,
            Body=body.encode("utf-8"),
            ContentType="application/json",
        )
    except (ClientError, BotoCoreError) as exc:
        logger.exception(
            "Fallo al escribir en S3",
            extra={"error_code": "storage_write_failed", "error_type": type(exc).__name__, "s3_key": s3_key},
        )
        raise ApiError(
            500,
            "storage_write_failed",
            "No se pudo guardar el resultado en S3. La solicitud no fue completada.",
            cache_state="MISS",
        ) from exc


def write_cache(cache_key: str, body: str) -> None:
    try:
        # SET con EX: la clave NUNCA queda sin expiración.
        get_redis().set(cache_key, body, ex=CACHE_TTL_SECONDS)
    except RedisError as exc:
        logger.exception(
            "Fallo al escribir en Redis",
            extra={"error_code": "cache_write_failed", "error_type": type(exc).__name__},
        )
        raise ApiError(
            500,
            "cache_write_failed",
            "El resultado se guardó en S3, pero no se pudo escribir en la caché (Redis).",
            cache_state="MISS",
        ) from exc


# --------------------------------------------------------------------------- #
# Respuestas HTTP (formato de respuesta de Lambda proxy, payload v2.0)
# --------------------------------------------------------------------------- #
def make_response(status: int, body: str, cache_state: str | None = None, ttl: int | None = None) -> dict[str, Any]:
    headers = {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"}
    if cache_state:
        headers["X-Cache"] = cache_state
    if ttl is not None and ttl >= 0:
        headers["X-Cache-TTL"] = str(ttl)
    return {"statusCode": status, "headers": headers, "isBase64Encoded": False, "body": body}


def error_response(err: ApiError, request_id: str) -> dict[str, Any]:
    body = json.dumps({"error": err.error, "message": err.message, "requestId": request_id}, separators=(",", ":"))
    return make_response(err.status_code, body, cache_state=err.cache_state)


# --------------------------------------------------------------------------- #
# Handler
# --------------------------------------------------------------------------- #
def _handle(event: dict[str, Any]) -> dict[str, Any]:
    if not RESULTS_BUCKET or not REDIS_HOST:
        logger.error("Configuración incompleta: faltan RESULTS_BUCKET o REDIS_HOST", extra={"error_code": "misconfigured"})
        raise ApiError(500, "misconfigured", "El servicio no está configurado correctamente.")

    payload = parse_body(event)
    digest = hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()
    result_id = resolve_result_id(payload, digest)
    cache_key = f"{CACHE_KEY_PREFIX}{digest}"
    log_ctx = {"cache_key_prefix": digest[:12]}

    cached, remaining_ttl = read_cache(cache_key)
    if cached is not None:
        logger.info("Cache HIT", extra={**log_ctx, "cache_state": "HIT"})
        return make_response(200, cached, cache_state="HIT", ttl=remaining_ttl)

    now = datetime.now(timezone.utc)
    s3_key = f"{RESULTS_PREFIX}/{now:%Y-%m-%d}/{result_id}.json"
    result = process_payload(payload, digest, result_id, s3_key, now)
    body = json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=True)

    write_s3(s3_key, body)  # si falla -> 500; no se cachea ni se responde éxito
    write_cache(cache_key, body)

    logger.info("Cache MISS procesado", extra={**log_ctx, "cache_state": "MISS", "s3_key": s3_key})
    return make_response(200, body, cache_state="MISS", ttl=CACHE_TTL_SECONDS)


def process_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    request_id = getattr(context, "aws_request_id", "local")
    try:
        return _handle(event)
    except ApiError as err:
        if err.status_code < 500:
            logger.warning("Solicitud rechazada", extra={"error_code": err.error})
        return error_response(err, request_id)
    except Exception:  # noqa: BLE001 - última red de seguridad: nunca dejar escapar un 502
        logger.exception("Error no controlado", extra={"error_code": "internal_error"})
        return error_response(
            ApiError(500, "internal_error", "Error interno inesperado. Consulte los logs con el requestId indicado."),
            request_id,
        )
