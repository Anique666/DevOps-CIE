# syntax=docker/dockerfile:1
# Lightweight, reproducible base image.
FROM python:3.12-slim

# Fail fast, do not write .pyc files (the root filesystem is read-only at run
# time), and keep logs unbuffered so `docker logs` shows them immediately.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    INPUT_DIR=/data

# Create a fixed, unprivileged runtime identity. A fixed UID/GID makes the
# Kubernetes securityContext reproducible as well.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home \
       --home-dir /app --shell /usr/sbin/nologin app

WORKDIR /app

# Install dependencies as root, before dropping privileges.
COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && rm -f requirements.txt

# Application code is owned by root and not writable by the runtime user.
COPY app/app.py ./app.py
RUN chown -R root:root /app && chmod -R a-w /app

# Runtime data is NOT copied into the image. It is mounted at /data.
USER 10001:10001

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2)"

# gunicorn: two workers, access/error logs to stdout/stderr.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
     "--access-logfile", "-", "--error-logfile", "-", "app:app"]
