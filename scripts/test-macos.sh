#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O macos/Protocol.swift tests/ProtocolTests.swift -o build/protocol-tests
./build/protocol-tests "$@"
