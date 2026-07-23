#!/bin/sh
set -e
vendor_directory="$(dirname "$0")/../vendor"
if [ -d "$vendor_directory/swift-sodium" ]; then
  echo "swift-sodium already vendored"
  exit 0
fi
git clone --depth 1 --branch 0.9.1 https://github.com/jedisct1/swift-sodium "$vendor_directory/swift-sodium"
