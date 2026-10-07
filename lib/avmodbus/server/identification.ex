defmodule AVModbus.Server.Identification do
  @moduledoc """
  Read Device Identification (`0x2B/0x0E`) の validation と response paging を提供します。

  identification object は object id (`0..255`) から binary value への map です。
  Modbus specification では object `0`、`1`、`2` が必須です。
  """

  @object_room 253 - 7
  @max_value_size @object_room - 2

  @type objects :: %{byte() => binary()}

  @doc "server identification object map を検証します。"
  @spec validate(term()) :: {:ok, objects()} | {:error, term()}
  def validate(objects) when is_map(objects) do
    with :ok <- validate_objects(:maps.to_list(objects)),
         :ok <- require_basic_objects(objects) do
      {:ok, objects}
    end
  end

  def validate(_objects), do: {:error, :invalid_identification}

  @doc false
  @spec answer(objects(), AVModbus.PDU.request()) :: AVModbus.PDU.result()
  def answer(objects, {:read_device_identification, :individual, id}) do
    case Map.fetch(objects, id) do
      {:ok, value} -> {:ok, response(objects, false, 0, [{id, value}])}
      :error -> {:error, {:exception, :illegal_data_address}}
    end
  end

  def answer(objects, {:read_device_identification, category, from}) do
    last_id = min(last(category), last(level(objects)))

    ids =
      objects
      |> Map.keys()
      |> within(last_id, [])
      |> sort([])

    from = if member?(ids, from), do: from, else: 0
    {sent, rest} = fit(drop_before(ids, from), objects, @object_room, [])

    case rest do
      [] -> {:ok, response(objects, false, 0, sent)}
      [next | _rest] -> {:ok, response(objects, true, next, sent)}
    end
  end

  defp validate_objects([]), do: :ok

  defp validate_objects([{id, value} | rest])
       when is_integer(id) and id >= 0 and id <= 255 and is_binary(value) and
              byte_size(value) <= @max_value_size,
       do: validate_objects(rest)

  defp validate_objects([object | _rest]),
    do: {:error, {:invalid_identification_object, object}}

  defp require_basic_objects(objects) do
    missing = missing_basic(objects, [0, 1, 2], [])

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_identification_objects, missing}}
    end
  end

  defp missing_basic(_objects, [], missing), do: reverse(missing, [])

  defp missing_basic(objects, [id | rest], missing) do
    if Map.has_key?(objects, id) do
      missing_basic(objects, rest, missing)
    else
      missing_basic(objects, rest, [id | missing])
    end
  end

  defp response(objects, more_follows, next_object_id, sent) do
    %{
      conformity_level: 0x80 + level(objects),
      more_follows: more_follows,
      next_object_id: next_object_id,
      objects: sent
    }
  end

  defp level(objects), do: level(Map.keys(objects), 1)
  defp level([], result), do: result
  defp level([id | _rest], _result) when id >= 0x80, do: 3
  defp level([id | rest], _result) when id >= 3, do: level(rest, 2)
  defp level([_id | rest], result), do: level(rest, result)

  defp last(:basic), do: 2
  defp last(:regular), do: 0x7F
  defp last(:extended), do: 0xFF
  defp last(1), do: 2
  defp last(2), do: 0x7F
  defp last(3), do: 0xFF

  defp within([], _last_id, result), do: result

  defp within([id | rest], last_id, result) when id <= last_id,
    do: within(rest, last_id, [id | result])

  defp within([_id | rest], last_id, result), do: within(rest, last_id, result)

  defp sort([], result), do: result
  defp sort([id | rest], result), do: sort(rest, insert(id, result))

  defp insert(id, []), do: [id]
  defp insert(id, [next | rest]) when id <= next, do: [id, next | rest]
  defp insert(id, [next | rest]), do: [next | insert(id, rest)]

  defp member?([], _value), do: false
  defp member?([value | _rest], value), do: true
  defp member?([_value | rest], wanted), do: member?(rest, wanted)

  defp drop_before([], _from), do: []
  defp drop_before([id | rest], from) when id < from, do: drop_before(rest, from)
  defp drop_before(ids, _from), do: ids

  defp fit([id | rest] = remaining, objects, room, sent) do
    size = 2 + byte_size(objects[id])

    if size <= room do
      fit(rest, objects, room - size, [{id, objects[id]} | sent])
    else
      {reverse(sent, []), remaining}
    end
  end

  defp fit([], _objects, _room, sent), do: {reverse(sent, []), []}

  defp reverse([], result), do: result
  defp reverse([value | rest], result), do: reverse(rest, [value | result])
end
