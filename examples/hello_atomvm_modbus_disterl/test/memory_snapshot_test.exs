defmodule DisterlProbe.MemorySnapshotTest do
  use ExUnit.Case, async: true

  alias DisterlProbe.MemorySnapshot

  test "reports ESP32 heap fields in a stable log format" do
    snapshot = %{
      free_heap_bytes: 100_000,
      largest_free_block_bytes: 50_000,
      minimum_free_heap_bytes: 90_000
    }

    assert MemorySnapshot.format(snapshot) ==
             "free_heap_bytes=100000 largest_free_block_bytes=50000 " <>
               "minimum_free_heap_bytes=90000"
  end

  test "marks ESP32 heap data unavailable on the host" do
    assert MemorySnapshot.capture() == nil
    assert MemorySnapshot.format(nil) == "free_heap_bytes=unavailable"
  end
end
