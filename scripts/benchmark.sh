#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
trap 'rm -f .build/run-benchmark' EXIT
touch .build/run-benchmark
python3 scripts/generate-project.py
xcodebuild -project Resim.xcodeproj -scheme Resim -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode \
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO \
  -only-testing:ResimTests/BenchmarkTests/testReleaseCorpusBenchmark test "$@"
python3 - <<'PY'
import json
r=json.load(open('.build/benchmark.json'))
print(f"OS: {r['os']} | Arch: {r['architecture']} | Host peak RSS: {r['peak_host_rss_bytes']/2**20:.1f} MiB")
for x in r['rows']:
 print(f"{x['fixture']:26s} {x['mode']:10s} median {x['median_ms']:8.1f} ms p95 {x['p95_ms']:8.1f} ms saved {x['saved_bytes']:7d} B")
print('Report: .build/benchmark.json')
PY
