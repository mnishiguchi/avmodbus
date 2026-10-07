defmodule AVModbus.UART do
  @moduledoc """
  RS485 transceiver 経由の Modbus serial 通信に使う薄い AtomVM UART adapter です。
  """

  @compile {:no_warn_undefined, :uart}

  @peripheral Application.compile_env(:avmodbus, :uart_peripheral, "UART1")
  @speed Application.compile_env(:avmodbus, :uart_speed, 9_600)
  @tx_pin Application.compile_env(:avmodbus, :uart_tx_pin, nil)
  @rx_pin Application.compile_env(:avmodbus, :uart_rx_pin, nil)
  @data_bits Application.compile_env(:avmodbus, :uart_data_bits, 8)
  @stop_bits Application.compile_env(:avmodbus, :uart_stop_bits, 1)
  @parity Application.compile_env(:avmodbus, :uart_parity, :none)

  def open do
    if is_nil(@tx_pin) or is_nil(@rx_pin) do
      {:error, :uart_pins_not_configured}
    else
      opts = [
        speed: @speed,
        tx: @tx_pin,
        rx: @rx_pin,
        data_bits: @data_bits,
        stop_bits: @stop_bits,
        flow_control: :none,
        parity: @parity
      ]

      case :uart.open(@peripheral, opts) do
        {:error, _reason} = error -> error
        uart -> {:ok, uart}
      end
    end
  end

  def write(uart, data), do: :uart.write(uart, data)
  def read(uart, timeout_ms), do: :uart.read(uart, timeout_ms)
  def close(uart), do: :uart.close(uart)
end
