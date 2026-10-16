defmodule DisterlProbe.Payload do
  @moduledoc false

  @pattern <<0x4D, 0x6F, 0x64, 0x62, 0x75, 0x73, 0x44, 0x69, 0x73, 0x74, 0x00, 0xFF, 0x55, 0xAA,
             0x0D, 0x0A>>
  @pattern_size byte_size(@pattern)

  def build(size) when is_integer(size) and size >= 0 do
    complete = :binary.copy(@pattern, div(size, @pattern_size))
    remainder = rem(size, @pattern_size)
    <<tail::binary-size(remainder), _rest::binary>> = @pattern
    complete <> tail
  end

  def valid?(payload) when is_binary(payload), do: payload == build(byte_size(payload))
end
