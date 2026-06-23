# syntax=docker/dockerfile:1.6
# chat-room-server — FastAPI app image.
#
# Runtime configuration (DB host, JWT secret, SMTP creds, etc.) is supplied
# via environment variables by the k8s manifests. Nothing host-specific is
# baked into the image.

FROM python:3.11-slim AS base

# Avoid .pyc files and force unbuffered stdout so container logs stream cleanly.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Pillow + cryptography pull in a few system libs on Debian slim. Install
# only what we need, in one layer, to keep the image small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libjpeg62-turbo \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user to run the app. UID 10001 leaves headroom above the
# standard 1000-range UIDs that host volume mounts often collide with.
RUN groupadd --system --gid 10001 app \
    && useradd  --system --uid 10001 --gid app --home /app --shell /usr/sbin/nologin app

WORKDIR /app

# Install Python deps first so changes to the app code don't bust the
# dependency cache layer.
COPY requirements.txt ./
RUN pip install -r requirements.txt

# Copy the rest of the source. .dockerignore keeps secrets, build artefacts,
# and VCS metadata out of the build context.
COPY app/ ./app/

# Static files need to be readable by the unprivileged user.
RUN chown -R app:app /app

USER app

EXPOSE 8000

# Healthcheck uses the in-app /healthz endpoint, which is intentionally
# DB-free (see app/main.py) so a transient DB blip doesn't fail the probe
# and trigger a needless pod restart.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
