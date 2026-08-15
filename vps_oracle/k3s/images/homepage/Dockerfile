# Security patch wrapper around the upstream homepage image.
# CVE-2026-59873 (node-tar DoS) lives in npm's internal bundled copy
# (/usr/local/lib/node_modules/npm/node_modules/tar), version tied to the
# node base image, not the app — so no upstream release fixes it. Replacing
# npm with 11.19.0 (bundles tar 7.5.19) clears the finding. Upgraded to
# v2.0.0 at the same time: v1.13.2 also carries tar@7.5.11 as an app
# dependency (pnpm), which a wrapper can't remove; v2.0.0 dropped it.
FROM ghcr.io/gethomepage/homepage:v2.0.0
RUN npm install -g npm@11.19.0
