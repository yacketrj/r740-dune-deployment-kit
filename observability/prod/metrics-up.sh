#!/usr/bin/env bash
# Bring up the managed metrics services with our overrides. Usage: metrics-up.sh [service...]
set -eu
cd /home/dune/dune-awakening-selfhost-docker
COMPOSE_PROJECT_NAME=dune-awakening-selfhost-docker-metrics COMPOSE_IGNORE_ORPHANS=true \
  docker compose -f docker-compose.metrics.yml -f /home/dune/observability/docker-compose.metrics.override.yml up -d "$@"
