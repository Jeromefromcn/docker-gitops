# Security patch wrapper around the upstream trilium image.
# Same CVE-2026-59873 story as homepage: the vulnerable tar is npm's
# internal bundled copy (npm 11.16.0 bundles 7.5.15), not an app
# dependency. Replacing npm with 11.19.0 (bundles tar 7.5.19) clears it.
FROM triliumnext/trilium:v0.104.1
RUN npm install -g npm@11.19.0
