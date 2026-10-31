"""Secure file-processing worker API.

Endpoints
---------
GET /health
    Report service status plus whether the configured input directory exists
    and is readable. Returns HTTP 503 when the input directory is unusable so
    that Docker/Kubernetes health probes fail correctly.

GET /process?file=<name>
    Count the words in ``<name>`` inside ``INPUT_DIR``.

Security properties
-------------------
* API users never supply a filesystem path. Only a single basename that
  matches a strict allow-list pattern is accepted.
* The resolved path must remain inside ``INPUT_DIR``. This blocks ``..``
  traversal and symlinks that point outside the directory.
* Only regular files up to ``MAX_FILE_SIZE`` bytes are read.
* The application opens files read-only and never writes to the input
  directory. Read-only enforcement is applied again by Docker/Kubernetes.
"""

from __future__ import annotations

import logging
import os
import re
from pathlib import Path

from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

INPUT_DIR = Path(os.environ.get("INPUT_DIR", "/data")).resolve()
MAX_FILE_SIZE = int(os.environ.get("MAX_FILE_SIZE", "1048576"))  # 1 MiB

# A single path component only: letters, digits, dot, underscore, hyphen.
# It must start with an alphanumeric character, which also rules out hidden
# files and the special names "." / "..".
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("cie-worker")

app = Flask(__name__)


def _error(code: str, message: str, status: int, **details):
    """Return a consistent structured JSON error response."""
    body = {"status": "error", "error": {"code": code, "message": message}}
    if details:
        body["details"] = details
    return jsonify(body), status


@app.get("/health")
def health():
    exists = INPUT_DIR.is_dir()
    readable = exists and os.access(INPUT_DIR, os.R_OK | os.X_OK)
    body = {
        "status": "ok" if readable else "degraded",
        "service": "cie-worker",
        "input_dir": str(INPUT_DIR),
        "input_dir_exists": exists,
        "input_dir_readable": readable,
    }
    return jsonify(body), (200 if readable else 503)


@app.get("/process")
def process():
    raw_name = request.args.get("file")
    if raw_name is None or raw_name == "":
        return _error(
            "missing_file_parameter",
            "Query parameter 'file' is required, for example /process?file=sample.txt.",
            400,
        )

    # Defence 1: exactly one safe path component. Rejects "/etc/passwd",
    # "../../etc/shadow", "..", absolute paths and URL-encoded separators
    # that Flask has already decoded.
    if (
        raw_name != os.path.basename(raw_name)
        or not SAFE_NAME.fullmatch(raw_name)
        or raw_name in (".", "..")
    ):
        log.warning("Rejected unsafe filename: %r", raw_name)
        return _error(
            "invalid_filename",
            "Invalid filename. Use a plain file name such as 'sample.txt'.",
            400,
        )

    if not INPUT_DIR.is_dir():
        log.error("Input directory is unavailable: %s", INPUT_DIR)
        return _error(
            "input_directory_unavailable",
            "The configured input directory is not available inside the container.",
            500,
            input_dir=str(INPUT_DIR),
        )

    # Defence 2: resolve symlinks, then require containment in INPUT_DIR.
    try:
        target = (INPUT_DIR / raw_name).resolve(strict=True)
    except FileNotFoundError:
        log.info("File not found: %s", raw_name)
        return _error("file_not_found", f"No such file: {raw_name}", 404)
    except PermissionError:
        # Typical SELinux or DAC denial while resolving the path.
        log.warning("Permission denied resolving %s", raw_name)
        return _error(
            "file_inaccessible",
            "The worker is not permitted to read this file.",
            403,
        )
    except OSError as exc:
        log.exception("Could not resolve path for %s", raw_name)
        return _error("path_resolution_error", str(exc), 500)

    try:
        target.relative_to(INPUT_DIR)
    except ValueError:
        log.warning("Blocked path escape for %r -> %s", raw_name, target)
        return _error(
            "path_traversal",
            "Resolved path is outside the permitted input directory.",
            400,
        )

    if not target.is_file():
        return _error("not_a_regular_file", f"Not a regular file: {raw_name}", 400)

    try:
        size = target.stat().st_size
        if size > MAX_FILE_SIZE:
            return _error(
                "file_too_large",
                f"File exceeds the {MAX_FILE_SIZE} byte limit.",
                413,
            )
        text = target.read_text(encoding="utf-8", errors="replace")
    except PermissionError:
        log.warning("Permission denied reading %s", target)
        return _error(
            "file_inaccessible",
            "The worker is not permitted to read this file.",
            403,
        )
    except OSError as exc:
        log.exception("Read error for %s", target)
        return _error("read_error", str(exc), 500)

    word_count = len(text.split())
    log.info(
        "Processed file=%s words=%d bytes=%d",
        raw_name,
        word_count,
        size,
    )
    return jsonify(
        {
            "status": "ok",
            "service": "cie-worker",
            "file": raw_name,
            "word_count": word_count,
            "character_count": len(text),
            "size_bytes": size,
        }
    )


@app.errorhandler(HTTPException)
def handle_http_exception(exc: HTTPException):
    return _error(
        exc.name.lower().replace(" ", "_"),
        exc.description or exc.name,
        exc.code or 500,
    )


@app.errorhandler(Exception)
def handle_unexpected(exc: Exception):
    log.exception("Unhandled application error")
    return _error("internal_error", "Unexpected server error.", 500)


if __name__ == "__main__":
    # Development only; the container runs gunicorn instead.
    app.run(host="0.0.0.0", port=5000)
