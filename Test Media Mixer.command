#!/bin/bash
# Double-click to run every test. Output is also saved to build/test.log.
cd "$(dirname "$0")"
mkdir -p build
bash scripts/test.sh 2>&1 | tee build/test.log
echo "exit: ${PIPESTATUS[0]}" >> build/test.log
