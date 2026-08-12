#!/bin/bash
set -e

pnpm dlx biome check --write --no-errors-on-unmatched --files-ignore-unknown=true . && \
git update-index --again 