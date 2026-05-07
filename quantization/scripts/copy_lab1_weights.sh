#!/usr/bin/env bash
# Copy Lab 1 pretrained weights into Final_project/quantization/weights/
# so we don't re-train from scratch every time.
#
# Source: ~/EE/碩ㄧ課/AOC/aoc2026-lab1/weights/
# - best_vgg_cifar10.pth   FP32 baseline (~13.4 MB, 91.79% acc)
# - PTQ_vgg_cifar10.pth    INT8 PTQ (~3.4 MB, 91.58% acc)
#
# These files are .gitignore'd; each developer copies them locally.

set -euo pipefail

SRC="${HOME}/EE/碩ㄧ課/AOC/aoc2026-lab1/weights"
# Resolve project root from this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="$(cd "${SCRIPT_DIR}/.." && pwd)/weights"

if [[ ! -d "${SRC}" ]]; then
  echo "ERROR: Lab 1 weights directory not found at ${SRC}" >&2
  echo "       If your Lab 1 lives elsewhere, edit SRC in this script." >&2
  exit 1
fi

mkdir -p "${DST}"
cp -v "${SRC}/best_vgg_cifar10.pth" "${DST}/"
cp -v "${SRC}/PTQ_vgg_cifar10.pth" "${DST}/"

echo
echo "✓ Copied Lab 1 weights into ${DST}"
ls -lh "${DST}"
