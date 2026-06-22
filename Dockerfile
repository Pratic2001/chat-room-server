# syntax=docker/dockerfile:1.7
# -------- builder --------
FROM python:3.12-slim AS builder
WORKDIR /build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc libffi-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# -------- runtime --------
FROM python:3.12-slim AS runtime
WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Non-root user. UID 1001 is arbitrary; the Deployment also pins runAsUser: 1001.
# Port 8000 doesn't need root, so this is fine.
RUN groupadd --system --gid 1001 chatroom \
 && useradd  --system --uid 1001 --gid chatroom --home /app --shell /usr/sbin/nologin chatroom \
 && mkdir -p /app /tmp \
 && chown -R chatroom:chatroom /app /tmp

# Copy installed packages from the builder
COPY --from=builder /install /usr/local

# Copy the application
COPY --chown=chatroom:chatroom app/ /app/app/

USER chatroom
EXPOSE 8000

# Healthcheck uses the /healthz route added to app/main.py. No DB hit, so a
# transient DB blip doesn't kill the pod.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; \
       r=urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2); \
       sys.exit(0 if r.status==200 else 1)"]

# --proxy-headers makes uvicorn honour X-Forwarded-Proto / X-Forwarded-For
# set by the Jenkins host's nginx.
# --workers 2 covers the brief overlap during a rolling update.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--workers", "2", \
     "--proxy-headers"]
