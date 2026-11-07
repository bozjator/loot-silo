#!/usr/bin/env bash
# Rebuilds the README media in docs/media/ (M53). Run from anywhere.
# Reads the real library read-only; works on a temp copy of a few Kenney packs.
set -euo pipefail
cd "$(dirname "$0")/../.."
README_MEDIA=1 xvfb-run -a -s "-screen 0 1440x900x24" \
  flutter test integration_test/readme_media_test.dart -d linux
python3 tool/readme_media/make_media.py
