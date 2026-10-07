defmodule AVModbus.MemoryTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Memory, Server}

  defp memory(options) do
    start_supervised!({Memory, options}, id: make_ref())
  end

  test "stores sparse values in all four data-model tables" do
    memory =
      memory(coils: 10, discrete_inputs: 10, holding_registers: 10, input_registers: 10)

    assert Memory.get(memory, :coil, 2, 3) == [false, false, false]
    assert :ok = Memory.put(memory, :coil, 3, true)
    assert Memory.get(memory, :coil, 2, 3) == [false, true, false]

    assert :ok = Memory.put(memory, :discrete_input, 0, [true, false])
    assert Memory.get(memory, :discrete_input, 0, 2) == [true, false]

    assert :ok = Memory.put(memory, :holding_register, 1, [18, 1000, 3])
    assert Memory.get(memory, :holding_register, 1, 3) == [18, 1000, 3]

    assert :ok = Memory.put(memory, :input_register, 9, 65_535)
    assert Memory.get(memory, :input_register, 9) == [65_535]
  end

  test "handles common reads, writes, and address exceptions" do
    memory = memory(coils: 20, holding_registers: 20)
    handler = {Memory, memory}

    assert Server.handle_request(handler, 1, {:read_coils, 0, 3}) ==
             {:ok, [false, false, false]}

    assert Server.handle_request(handler, 1, {:write_multiple_coils, 1, [true, false, true]}) ==
             :ok

    assert Server.handle_request(handler, 1, {:read_coils, 0, 5}) ==
             {:ok, [false, true, false, true, false]}

    assert Server.handle_request(handler, 1, {:write_multiple_registers, 5, [10, 20]}) == :ok
    assert Server.handle_request(handler, 1, {:read_holding_registers, 5, 2}) == {:ok, [10, 20]}

    assert Server.handle_request(handler, 1, {:read_holding_registers, 19, 2}) ==
             {:error, {:exception, :illegal_data_address}}

    assert Server.handle_request(handler, 1, :read_exception_status) ==
             {:error, {:exception, :illegal_function}}
  end

  test "applies mask writes and writes before a combined read" do
    memory = memory(holding_registers: 20)
    handler = {Memory, memory}
    assert :ok = Memory.put(memory, :holding_register, 4, 0x0012)

    assert Server.handle_request(handler, 1, {:mask_write_register, 4, 0x00F2, 0x0025}) == :ok
    assert Memory.get(memory, :holding_register, 4) == [0x0017]

    assert Server.handle_request(
             handler,
             1,
             {:read_write_multiple_registers, 8, 3, 8, [5, 6]}
           ) == {:ok, [5, 6, 0]}
  end

  test "reads FIFO queues from holding registers" do
    memory = memory(holding_registers: 40)
    handler = {Memory, memory}
    assert :ok = Memory.put(memory, :holding_register, 10, [2, 31, 32])
    assert Server.handle_request(handler, 1, {:read_fifo_queue, 10}) == {:ok, [31, 32]}

    assert :ok = Memory.put(memory, :holding_register, 10, 32)

    assert Server.handle_request(handler, 1, {:read_fifo_queue, 10}) ==
             {:error, {:exception, :illegal_data_value}}
  end

  test "stores and reads file records" do
    memory = memory(files: 3)
    handler = {Memory, memory}

    assert Server.handle_request(handler, 1, {:write_file_record, [{2, 9998, [1, 2]}]}) == :ok

    assert Server.handle_request(
             handler,
             1,
             {:read_file_record, [{2, 9998, 2}, {3, 0, 1}]}
           ) == {:ok, [[1, 2], [0]]}

    assert Server.handle_request(handler, 1, {:read_file_record, [{4, 0, 1}]}) ==
             {:error, {:exception, :illegal_data_address}}
  end

  test "validates direct access and configuration" do
    memory = memory(coils: 2, holding_registers: 2)

    assert Memory.put(memory, :coil, 0, 1) == {:error, :invalid_value}
    assert Memory.put(memory, :holding_register, 0, 65_536) == {:error, :invalid_value}
    assert Memory.get(memory, :holding_register, 1, 2) == {:error, :invalid_address_range}
    assert Memory.get(memory, :unknown, 0) == {:error, :invalid_table}

    assert Memory.start_link(coils: 65_537) == {:error, {:invalid_size, :coils}}
    assert Memory.start_link(files: 101) == {:error, {:invalid_size, :files}}
    assert Memory.start_link(other: 1) == {:error, {:invalid_option, {:other, 1}}}
  end
end
