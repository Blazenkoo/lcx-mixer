#!/bin/bash
# Double-click to build, install and launch LCX Mixer. Output is also saved to build/build.log.
cd "$(dirname "$0")"
mkdir -p build
bash scripts/build.sh 2>&1 | tee build/build.log
echo "exit: ${PIPESTATUS[0]}" >> build/build.log
