#!/usr/bin/env bash
# Rebuilds the plans image from the latest plans repo and redeploys it.
# No registry: build and compose both run on this host.
set -euo pipefail

PLANS_REPO="/home/ubuntu/jerome/plans"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

cd "$PLANS_REPO"
git pull
SHA="$(git rev-parse --short HEAD)"
IMAGE="plans:$SHA"

docker build -t "$IMAGE" "$PLANS_REPO"

sed -i "s|image: plans:.*|image: $IMAGE|" "$COMPOSE_FILE"

cd "$COMPOSE_DIR"
docker compose up -d

echo "Deployed $IMAGE."
echo "Review and commit: cd $COMPOSE_DIR && git diff docker-compose.yml"
