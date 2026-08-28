FROM python:3.12.13-alpine3.22

# hello-backend: lightweight HTTP service (stdlib only) replacing the old
# static nginx. Serves index.html at runtime (so the canary ConfigMap mount at
# /usr/share/nginx/html/index.html keeps working) plus /slow, /fail-503,
# /fail-500 and /healthz for mesh resilience testing. Runs unprivileged on
# port 8080. See app.py for the endpoints and env overrides.

WORKDIR /app
COPY app.py index.html ./
COPY index.html /usr/share/nginx/html/index.html

# runAsNonRoot: true in the deployment requires a non-root image user.
# Port 8080 is >1024 so no privileged bind is needed.
USER nobody

EXPOSE 8080

CMD ["python3", "app.py"]
