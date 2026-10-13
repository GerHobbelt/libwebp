#!/usr/bin/env bash
# Image sets (disjoint) of the Windows runs of .github/workflows/natives-windows-x64.yml; prints paths.
#   bench  webp4j's test photos (RGB 3.2 MP, RGBA 1 MP) + the first 2 Windows wallpaper photos
#   train  PGO training: webp4j's test GIF (palette graphic) + up to 4 other Windows images
set -euo pipefail
R=${WEBP4J:-webp4j}/src/test/resources
wall() { find /c/Windows/Web -type f -iname '*.jpg' -size +300k 2>/dev/null | sort | head -2; }
case $1 in
    bench) printf '%s\n' "$R/test_rgb.png" "$R/test_rgba.png"; wall ;;
    train) printf '%s\n' "$R/test_gif.gif"
           find /c/Windows/Web -type f \( -iname '*.jpg' -o -iname '*.png' \) -size +100k 2>/dev/null | sort \
               | grep -vxF -f <(wall) | head -4 || true ;;
    *) echo "usage: $0 bench|train" >&2; exit 2 ;;
esac
