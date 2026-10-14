#!/usr/bin/env python3
"""Empaqueta la Lambda `process_handler` en un ZIP determinista.

Pasos: instala requirements.txt (wheels para el runtime/arquitectura de Lambda),
copia lambda/*.py y genera build/process_handler.zip. Solo usa la biblioteca estándar.

Dos modos de uso:
  1) Terraform (data "external"): sin argumentos; lee un JSON por stdin y escribe un JSON por stdout
     {"zip_path": "...", "source_code_hash": "<sha256 base64>", "source_digest": "<sha256 hex>"}.
     Todo el ruido (pip, logs) va a stderr para no corromper el JSON.
  2) Manual: python scripts/package_lambda.py build [--python-version 3.12] [--architecture x86_64]

Idempotente: si las entradas no cambiaron (sello en build/.package-stamp) no reconstruye nada.
Determinista: entradas ordenadas, marcas de tiempo fijas y sin .pyc, de modo que las mismas
entradas producen el mismo hash.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ZIP_NAME = "process_handler.zip"
STAMP_NAME = ".package-stamp"
FIXED_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
PIP_PLATFORM_BY_ARCHITECTURE = {
    "x86_64": "manylinux2014_x86_64",
    "arm64": "manylinux2014_aarch64",
}


class PackagingError(Exception):
    """Error esperado de empaquetado (se informa por stderr y se sale con código 1)."""


def log(message: str) -> None:
    print(f"[package_lambda] {message}", file=sys.stderr, flush=True)


def compute_source_digest(
    source_dir: Path, requirements_file: Path, python_version: str, architecture: str
) -> str:
    """Hash (hex) de todo lo que influye en el contenido del ZIP."""
    sha = hashlib.sha256()
    for path in sorted(source_dir.glob("*.py")):
        sha.update(path.name.encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
    sha.update(requirements_file.read_bytes())
    sha.update(Path(__file__).resolve().read_bytes())
    sha.update(f"{python_version}|{architecture}".encode("utf-8"))
    return sha.hexdigest()


def install_dependencies(requirements_file: Path, target: Path, python_version: str, architecture: str) -> None:
    command = [
        sys.executable, "-m", "pip", "install",
        "--requirement", str(requirements_file),
        "--target", str(target),
        "--upgrade",
        "--no-compile",
        "--disable-pip-version-check",
        "--no-input",
        "--only-binary=:all:",
        "--implementation", "cp",
        "--python-version", python_version,
        "--platform", PIP_PLATFORM_BY_ARCHITECTURE[architecture],
    ]
    log("Instalando dependencias: " + " ".join(command[3:]))
    try:
        result = subprocess.run(command, stdout=sys.stderr, stderr=sys.stderr, check=False)
    except OSError as exc:
        raise PackagingError(f"No se pudo ejecutar pip con {sys.executable}: {exc}") from exc
    if result.returncode != 0:
        raise PackagingError(
            "pip falló al instalar las dependencias (revisa conectividad, versión de pip y requirements.txt)."
        )


def build_zip(staging: Path, zip_path: Path) -> None:
    files = sorted(
        p for p in staging.rglob("*")
        if p.is_file() and "__pycache__" not in p.parts and p.suffix not in {".pyc", ".pyo"}
    )
    tmp_path = zip_path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(staging).as_posix(), date_time=FIXED_ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    os.replace(tmp_path, zip_path)


def sha256_base64(path: Path) -> str:
    return base64.b64encode(hashlib.sha256(path.read_bytes()).digest()).decode("ascii")


def build(params: dict[str, str]) -> dict[str, str]:
    source_dir = Path(params["source_dir"]).resolve()
    requirements_file = Path(params["requirements_file"]).resolve()
    build_dir = Path(params["build_dir"]).resolve()
    python_version = params["python_version"]
    architecture = params["architecture"]

    if not re.fullmatch(r"3\.\d+", python_version):
        raise PackagingError(f"python_version inválida: {python_version!r} (se espera, por ejemplo, 3.12)")
    if architecture not in PIP_PLATFORM_BY_ARCHITECTURE:
        raise PackagingError(f"architecture inválida: {architecture!r} (x86_64 o arm64)")
    if not (source_dir / "handler.py").is_file():
        raise PackagingError(f"No existe {source_dir / 'handler.py'}")
    if not requirements_file.is_file():
        raise PackagingError(f"No existe {requirements_file}")

    build_dir.mkdir(parents=True, exist_ok=True)
    zip_path = build_dir / ZIP_NAME
    stamp_path = build_dir / STAMP_NAME
    digest = compute_source_digest(source_dir, requirements_file, python_version, architecture)

    if zip_path.is_file() and stamp_path.is_file() and stamp_path.read_text(encoding="utf-8").strip() == digest:
        log(f"Paquete al día ({digest[:12]}); no se reconstruye.")
    else:
        log(f"Construyendo paquete ({digest[:12]})...")
        staging = build_dir / "package"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True)

        install_dependencies(requirements_file, staging, python_version, architecture)
        for source_file in sorted(source_dir.glob("*.py")):
            shutil.copy2(source_file, staging / source_file.name)

        build_zip(staging, zip_path)
        stamp_path.write_text(digest + "\n", encoding="utf-8")
        log(f"Paquete creado: {zip_path} ({zip_path.stat().st_size} bytes)")

    return {
        "zip_path": str(zip_path),
        "source_code_hash": sha256_base64(zip_path),
        "source_digest": digest,
    }


def parse_cli(argv: list[str]) -> dict[str, str]:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Empaqueta la Lambda process_handler.")
    parser.add_argument("command", choices=["build"])
    parser.add_argument("--source-dir", default=str(repo_root / "lambda"))
    parser.add_argument("--requirements-file", default=str(repo_root / "lambda" / "requirements.txt"))
    parser.add_argument("--build-dir", default=str(repo_root / "build"))
    parser.add_argument("--python-version", default="3.12")
    parser.add_argument("--architecture", default="x86_64", choices=sorted(PIP_PLATFORM_BY_ARCHITECTURE))
    args = parser.parse_args(argv)
    return {
        "source_dir": args.source_dir,
        "requirements_file": args.requirements_file,
        "build_dir": args.build_dir,
        "python_version": args.python_version,
        "architecture": args.architecture,
    }


def main() -> int:
    try:
        if len(sys.argv) > 1:
            params = parse_cli(sys.argv[1:])
        else:
            params = json.load(sys.stdin)  # protocolo de data "external"
        result = build(params)
    except PackagingError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except (KeyError, json.JSONDecodeError) as exc:
        print(f"ERROR: parámetros de entrada inválidos o incompletos: {exc!r}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
