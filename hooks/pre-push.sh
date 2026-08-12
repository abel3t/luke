#!/bin/bash
set -e

echo "Running Biome checks..."
pnpm dlx biome check --no-errors-on-unmatched --files-ignore-unknown=true ./src