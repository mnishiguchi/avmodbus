defmodule DisterlProbe.MemorySnapshot do
  @moduledoc false

  @doc false
  def capture do
    case :erlang.system_info(:machine) do
      ~c"ATOM" ->
        %{
          free_heap_bytes: :erlang.system_info(:esp32_free_heap_size),
          largest_free_block_bytes: :erlang.system_info(:esp32_largest_free_block),
          minimum_free_heap_bytes: :erlang.system_info(:esp32_minimum_free_size)
        }

      _machine ->
        nil
    end
  end

  @doc false
  def format(nil), do: "free_heap_bytes=unavailable"

  def format(snapshot) do
    "free_heap_bytes=#{snapshot.free_heap_bytes} " <>
      "largest_free_block_bytes=#{snapshot.largest_free_block_bytes} " <>
      "minimum_free_heap_bytes=#{snapshot.minimum_free_heap_bytes}"
  end
end
