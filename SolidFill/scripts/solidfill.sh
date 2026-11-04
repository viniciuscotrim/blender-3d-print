#!/bin/zsh
# Uso: scripts/solidfill.sh modelo.3mf [saida.3mf] [--voxel 0.15] [--seal 2]
cd "$(dirname "$0")/.."
[ -x .build/release/solidfill ] || swift build -c release >&2
exec .build/release/solidfill "$@"
