#!/bin/bash
set -e

export PATH="$HOME/.local/bin:$PATH"

cd ~/app/workers/inference-worker

III_URL=ws://10.0.2.16:49134 iii worker start .