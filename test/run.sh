#!/bin/bash
# Run with: bash test/run.sh
# Everything that can be checked without a compositor.

cd "$(dirname "$0")/.." || exit 1
status=0
node test/model-test.js || status=1
bash test/store-test.sh || status=1
bash test/moneybird-test.sh || status=1
exit $status
