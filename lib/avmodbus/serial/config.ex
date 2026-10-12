defmodule AVModbus.Serial.Config do
  @moduledoc false

  alias AVModbus.RTU

  @default_speed Application.compile_env(:avmodbus, :uart_speed, 9_600)
  @configured_gap_ms Application.compile_env(:avmodbus, :modbus_rtu_gap_ms, 0)
  @configured_silence_ms Application.compile_env(:avmodbus, :modbus_silence_ms, 20)

  @spec defaults(atom(), term()) ::
          {:ok, %{gap: non_neg_integer(), silence: pos_integer()}} | {:error, term()}
  def defaults(mode, options) do
    with :ok <- validate(options),
         {:ok, speed} <- speed(options) do
      calculated_gap = div(RTU.frame_gap_us(speed) + 999, 1_000)

      gap =
        cond do
          mode == :ascii -> 0
          true -> effective_rtu_gap(calculated_gap, @configured_gap_ms)
        end

      silence =
        if mode == :ascii,
          do: @configured_silence_ms,
          else: max(@configured_silence_ms, 2 * calculated_gap)

      {:ok, %{gap: gap, silence: silence}}
    end
  end

  @spec validate(term()) :: :ok | {:error, :invalid_serial_options}
  def validate([]), do: :ok

  def validate([{key, _value} | rest]) when is_atom(key),
    do: validate(rest)

  def validate(_options), do: {:error, :invalid_serial_options}

  @doc false
  @spec effective_rtu_gap(non_neg_integer(), integer()) :: non_neg_integer()
  def effective_rtu_gap(calculated_gap, configured_minimum)
      when is_integer(calculated_gap) and calculated_gap >= 0 and
             is_integer(configured_minimum) do
    max(calculated_gap, configured_minimum)
  end

  defp speed(options) do
    case option(options, :speed, @default_speed) do
      speed when is_integer(speed) and speed > 0 -> {:ok, speed}
      speed -> {:error, {:invalid_serial_option, {:speed, speed}}}
    end
  end

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)
end
