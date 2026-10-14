"""Pruebas unitarias del handler (sin AWS ni Redis reales).

Ejecutar desde la raíz del repositorio:
    python -m unittest discover -s tests -v

Si `boto3`/`redis` no están instalados localmente, se registran módulos mínimos de
sustitución solo para poder importar el handler; las llamadas reales se reemplazan
por dobles en memoria (FakeRedis / FakeS3).
"""

import base64
import importlib
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lambda"))


def _install_stubs_if_needed() -> None:
    try:
        import boto3  # noqa: F401
        import redis  # noqa: F401
        return
    except ImportError:
        pass

    class _RedisError(Exception):
        pass

    class _ConnError(_RedisError):
        pass

    class _TimeoutErr(_RedisError):
        pass

    boto3_mod = types.ModuleType("boto3")
    boto3_mod.client = lambda *a, **k: None
    botocore = types.ModuleType("botocore")
    botocore_config = types.ModuleType("botocore.config")
    botocore_config.Config = lambda **k: None
    botocore_exc = types.ModuleType("botocore.exceptions")

    class _BotoCoreError(Exception):
        pass

    class _ClientError(Exception):
        pass

    botocore_exc.BotoCoreError = _BotoCoreError
    botocore_exc.ClientError = _ClientError

    redis_mod = types.ModuleType("redis")
    redis_mod.Redis = object
    redis_exc = types.ModuleType("redis.exceptions")
    redis_exc.RedisError = _RedisError
    redis_exc.ConnectionError = _ConnError
    redis_exc.TimeoutError = _TimeoutErr
    redis_backoff = types.ModuleType("redis.backoff")
    redis_backoff.ExponentialBackoff = lambda **k: None
    redis_retry = types.ModuleType("redis.retry")
    redis_retry.Retry = lambda *a, **k: None

    sys.modules.update(
        {
            "boto3": boto3_mod,
            "botocore": botocore,
            "botocore.config": botocore_config,
            "botocore.exceptions": botocore_exc,
            "redis": redis_mod,
            "redis.exceptions": redis_exc,
            "redis.backoff": redis_backoff,
            "redis.retry": redis_retry,
        }
    )


_install_stubs_if_needed()

import os  # noqa: E402

os.environ.update(
    {
        "RESULTS_BUCKET": "test-bucket",
        "RESULTS_PREFIX": "results",
        "REDIS_HOST": "redis.test.internal",
        "CACHE_TTL_SECONDS": "60",
    }
)
handler = importlib.import_module("handler")
RedisError = handler.RedisError
ClientError = handler.ClientError


class FakeRedis:
    def __init__(self):
        self.store = {}
        self.ttls = {}
        self.fail_read = False
        self.fail_write = False

    def pipeline(self, transaction=False):
        outer = self

        class Pipe:
            def __init__(self):
                self.ops = []

            def get(self, key):
                self.ops.append(("get", key))

            def ttl(self, key):
                self.ops.append(("ttl", key))

            def execute(self):
                if outer.fail_read:
                    raise RedisError("boom")
                out = []
                for op, key in self.ops:
                    out.append(outer.store.get(key) if op == "get" else outer.ttls.get(key, -2))
                return out

        return Pipe()

    def set(self, key, value, ex=None):
        if self.fail_write:
            raise RedisError("boom")
        assert ex is not None, "toda clave debe tener TTL explícito"
        self.store[key] = value
        self.ttls[key] = ex
        return True


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.fail = False

    def put_object(self, Bucket, Key, Body, ContentType):
        if self.fail:
            raise ClientError({"Error": {"Code": "AccessDenied", "Message": "denied"}}, "PutObject")
        self.objects[(Bucket, Key)] = Body


class Ctx:
    aws_request_id = "req-123"


def event(body, base64_encoded=False):
    if body is not None and not isinstance(body, str):
        body = json.dumps(body)
    if base64_encoded and body is not None:
        body = base64.b64encode(body.encode()).decode()
    return {
        "version": "2.0",
        "routeKey": "POST /process",
        "body": body,
        "isBase64Encoded": base64_encoded,
    }


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.redis = FakeRedis()
        self.s3 = FakeS3()
        patches = [
            mock.patch.object(handler, "get_redis", return_value=self.redis),
            mock.patch.object(handler, "get_s3", return_value=self.s3),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def call(self, ev):
        return handler.process_handler(ev, Ctx())

    def test_miss_then_hit(self):
        first = self.call(event({"id": "demo-001", "message": "hola"}))
        self.assertEqual(first["statusCode"], 200)
        self.assertEqual(first["headers"]["X-Cache"], "MISS")
        self.assertEqual(first["headers"]["X-Cache-TTL"], "60")
        result = json.loads(first["body"])
        self.assertEqual(result["output"]["reversed_strings"], {"message": "aloh"})
        self.assertRegex(result["s3_key"], r"^results/\d{4}-\d{2}-\d{2}/demo-001\.json$")
        self.assertIn(("test-bucket", result["s3_key"]), self.s3.objects)
        self.assertEqual(list(self.redis.ttls.values()), [60])

        s3_before = dict(self.s3.objects)
        self.redis.ttls[next(iter(self.redis.ttls))] = 42  # simula el paso del tiempo
        second = self.call(event({"id": "demo-001", "message": "hola"}))
        self.assertEqual(second["headers"]["X-Cache"], "HIT")
        self.assertEqual(second["headers"]["X-Cache-TTL"], "42")
        self.assertEqual(second["body"], first["body"])
        self.assertEqual(self.s3.objects, s3_before)  # no se reescribe en S3

    def test_property_order_does_not_change_cache_key(self):
        self.call(event('{"id":"a1","x":1,"y":{"b":2,"a":1}}'))
        hit = self.call(event('{"y":{"a":1,"b":2},"x":1,"id":"a1"}'))
        self.assertEqual(hit["headers"]["X-Cache"], "HIT")

    def test_expiry_causes_new_miss(self):
        self.call(event({"id": "e1", "v": "x"}))
        self.redis.store.clear()  # el TTL expiró
        again = self.call(event({"id": "e1", "v": "x"}))
        self.assertEqual(again["headers"]["X-Cache"], "MISS")

    def test_id_defaults_to_deterministic_hash(self):
        a = json.loads(self.call(event({"k": "v"}))["body"])
        self.redis.store.clear()
        b = json.loads(self.call(event({"k": "v"}))["body"])
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(len(a["id"]), 32)

    def test_base64_body(self):
        resp = self.call(event({"id": "b64", "m": "abc"}, base64_encoded=True))
        self.assertEqual(resp["statusCode"], 200)

    def test_invalid_json_returns_400(self):
        resp = self.call(event('{"id": '))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"])["error"], "invalid_json")
        self.assertEqual(json.loads(resp["body"])["requestId"], "req-123")

    def test_missing_body_and_wrong_types(self):
        self.assertEqual(self.call(event(None))["statusCode"], 400)
        self.assertEqual(self.call(event("[1,2]"))["statusCode"], 400)
        self.assertEqual(self.call(event("NaN"))["statusCode"], 400)

    def test_dangerous_id_rejected(self):
        for bad in ["../etc/passwd", "a/b", "", ".hidden", True, 1.5, "x" * 200]:
            resp = self.call(event({"id": bad}))
            self.assertEqual(resp["statusCode"], 400, msg=repr(bad))
        self.assertEqual(self.s3.objects, {})

    def test_s3_failure_is_not_hidden_and_not_cached(self):
        self.s3.fail = True
        resp = self.call(event({"id": "s3fail"}))
        self.assertEqual(resp["statusCode"], 500)
        self.assertEqual(json.loads(resp["body"])["error"], "storage_write_failed")
        self.assertEqual(self.redis.store, {})

    def test_redis_read_failure_returns_500(self):
        self.redis.fail_read = True
        resp = self.call(event({"id": "r1"}))
        self.assertEqual(resp["statusCode"], 500)
        self.assertEqual(json.loads(resp["body"])["error"], "cache_unavailable")
        self.assertNotIn("boom", resp["body"])  # sin detalles internos

    def test_redis_write_failure_returns_500(self):
        self.redis.fail_write = True
        resp = self.call(event({"id": "r2"}))
        self.assertEqual(resp["statusCode"], 500)
        self.assertEqual(json.loads(resp["body"])["error"], "cache_write_failed")

    def test_unexpected_exception_returns_500(self):
        with mock.patch.object(handler, "process_payload", side_effect=RuntimeError("secret detail")):
            resp = self.call(event({"id": "boom"}))
        self.assertEqual(resp["statusCode"], 500)
        self.assertNotIn("secret detail", resp["body"])


if __name__ == "__main__":
    unittest.main()
