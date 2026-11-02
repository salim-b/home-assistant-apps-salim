#!/usr/bin/env bash
#MISE description="Optimize a PNG image file in place"
#MISE dir="{{ cwd }}"
#USAGE arg "<file>" help="Path to the PNG image file to optimize" {
#USAGE   complete run="ls | grep -o '.*\\.png$'"
#USAGE }
#USAGE flag "--lossy" help="Whether or not to first run the image through lossy pngquant compression before applying remaining lossless optimization using oxipng; defaults to `false`; only recommended for images without color gradients"

set -euo pipefail

if [ "${usage_lossy:-false}" == "true" ]; then
  pngquant --quality=65-90 --speed=1 --strip --ext=.png --force "${usage_file:?}"
fi

oxipng --opt=max --strip=safe --alpha --interlace=off --zopfli --zi=100 "${usage_file:?}"
