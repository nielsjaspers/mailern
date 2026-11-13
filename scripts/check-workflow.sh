#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library Mailern/Core/*.swift Tests/WorkflowChecks.swift -o build/workflow-checks
build/workflow-checks
