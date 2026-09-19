#!/usr/bin/env bash
# Build plans on the gcp daemon from the private source on this host, then (re)start it.
# The source never leaves vps_oracle except as a transient build context over SSH;
# nothing is cloned or stored on gcp. Usage: ./deploy.sh [source-dir]
set -euo pipefail

SRC="${1:-/home/ubuntu/jerome/plans}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  echo "refusing to deploy: $SRC has uncommitted changes" >&2
  exit 1
fi
TAG="$(git -C "$SRC" rev-parse --short=7 HEAD)"

docker --context gcp build -t "plans:${TAG}" "$SRC"
sed -i "s|image: plans:.*|image: plans:${TAG}|" "$DIR/docker-compose.yml"
docker --context gcp compose -f "$DIR/docker-compose.yml" up -d
