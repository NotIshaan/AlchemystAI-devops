#!/bin/bash
set -e

export PATH="$HOME/.local/bin:$PATH"

cd ~/app/workers/caller-worker

III_URL=ws://localhost:49134 iii worker start .