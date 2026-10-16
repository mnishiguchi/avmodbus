defmodule DisterlProbe.Session do
  @moduledoc false

  @max_id 4_294_967_295

  def new_id do
    candidate =
      if :erlang.function_exported(:atomvm, :random, 0) do
        apply(:atomvm, :random, [])
      else
        :erlang.unique_integer([:positive])
      end

    new_id(candidate)
  end

  def new_id_except(previous) when is_integer(previous) and previous in 1..@max_id do
    new_id_except(previous, new_id())
  end

  @doc false
  def new_id_except(previous, candidate)
      when is_integer(previous) and previous in 1..@max_id and is_integer(candidate) do
    case new_id(candidate) do
      ^previous when previous == @max_id -> 1
      ^previous -> previous + 1
      id -> id
    end
  end

  # AtomVM represents the 32-bit result of atomvm:random/0 as a signed boxed
  # integer on 32-bit targets. Preserve its bit pattern as an unsigned ID.
  def new_id(candidate) when is_integer(candidate) do
    unsigned = if candidate < 0, do: candidate + @max_id + 1, else: candidate

    case rem(unsigned, @max_id + 1) do
      0 -> 1
      id -> id
    end
  end
end
