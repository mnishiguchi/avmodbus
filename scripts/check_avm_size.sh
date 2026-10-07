#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
artifact=${AVMODBUS_AVM_PATH:-$repo_dir/examples/hello_atomvm_modbus/sample_app.avm}
budget=${AVMODBUS_AVM_BUDGET_BYTES:-126200}

case "$budget" in
  ''|*[!0-9]*)
    echo "AVM size budget must be a non-negative integer: $budget" >&2
    exit 2
    ;;
esac

if [ ! -f "$artifact" ]; then
  echo "AVM artifact not found: $artifact" >&2
  exit 2
fi

size=$(wc -c < "$artifact" | tr -d '[:space:]')

if [ "$size" -gt "$budget" ]; then
  echo "AVM artifact exceeds budget: $size bytes > $budget bytes ($artifact)" >&2
  exit 1
fi

remaining=$((budget - size))
echo "AVM artifact size: $size bytes / $budget bytes ($remaining bytes remaining)"
