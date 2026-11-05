FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24

# hello-frontend: static index.html served by unprivileged nginx (uid 101,
# port 8080). The nginx server block (/ static, /api -> hello-backend) is not
# baked in here: k8s/frontend-configmap.yaml mounts it over default.conf.
#
# Upgrade packages on top of the pinned base: upstream's tag can lag Alpine's
# security fixes (CVE-2026-111497, brotli-libs 1.2.0-r1 -> 1.2.1-r0, was still
# unfixed in 1.31.7-alpine3.24), and require-vuln-scan-clean refuses any pod
# whose image carries a fixable CRITICAL.
USER root
RUN apk upgrade --no-cache
USER 101

COPY index.html /usr/share/nginx/html/index.html
