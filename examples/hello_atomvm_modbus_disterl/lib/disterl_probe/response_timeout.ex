defmodule DisterlProbe.ResponseTimeout do
  @moduledoc false

  defstruct [:initial, :current, :bulk]

  def new(initial, bulk)
      when is_integer(initial) and initial >= 0 and is_integer(bulk) and bulk >= 0 do
    %__MODULE__{initial: initial, current: initial, bulk: max(initial, bulk)}
  end

  def current(%__MODULE__{current: current}), do: current

  def observe_write(%__MODULE__{} = policy, write_size, max_chunk_size)
      when is_integer(write_size) and write_size >= 0 and is_integer(max_chunk_size) and
             max_chunk_size > 0 do
    if write_size > max_chunk_size, do: %{policy | current: policy.bulk}, else: policy
  end

  def reset(%__MODULE__{} = policy), do: %{policy | current: policy.initial}
end
