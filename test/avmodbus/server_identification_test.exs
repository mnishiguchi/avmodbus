defmodule AVModbus.Server.IdentificationTest do
  use ExUnit.Case, async: true

  alias AVModbus.Server.Identification

  @basic %{0 => "AVModbus", 1 => "XIAO ESP32-C5", 2 => "0.1.0"}

  test "validates required, bounded identification objects" do
    assert Identification.validate(@basic) == {:ok, @basic}
    assert Identification.validate([]) == {:error, :invalid_identification}

    assert Identification.validate(%{0 => "vendor"}) ==
             {:error, {:missing_identification_objects, [1, 2]}}

    assert Identification.validate(Map.put(@basic, 256, "invalid")) ==
             {:error, {:invalid_identification_object, {256, "invalid"}}}

    oversized = :binary.copy(<<0>>, 245)

    assert Identification.validate(Map.put(@basic, 3, oversized)) ==
             {:error, {:invalid_identification_object, {3, oversized}}}
  end

  test "answers category and individual access with a conformity level" do
    objects = Map.merge(@basic, %{3 => "site", 0x80 => "private"})

    assert {:ok,
            %{
              conformity_level: 0x83,
              more_follows: false,
              next_object_id: 0,
              objects: [{0, "AVModbus"}, {1, "XIAO ESP32-C5"}, {2, "0.1.0"}]
            }} = Identification.answer(objects, {:read_device_identification, :basic, 0})

    assert {:ok, %{objects: [{3, "site"}]}} =
             Identification.answer(objects, {:read_device_identification, :individual, 3})

    assert Identification.answer(objects, {:read_device_identification, :individual, 4}) ==
             {:error, {:exception, :illegal_data_address}}
  end

  test "paginates category responses without splitting objects" do
    objects =
      Map.merge(@basic, %{
        3 => :binary.copy("a", 120),
        4 => :binary.copy("b", 120),
        5 => :binary.copy("c", 120)
      })

    assert {:ok, first} =
             Identification.answer(objects, {:read_device_identification, :regular, 3})

    assert first.more_follows
    assert first.next_object_id == 5
    assert first.objects == [{3, objects[3]}, {4, objects[4]}]

    assert {:ok, second} =
             Identification.answer(
               objects,
               {:read_device_identification, :regular, first.next_object_id}
             )

    refute second.more_follows
    assert second.objects == [{5, objects[5]}]
  end

  test "unknown category starting object restarts at the first object" do
    assert {:ok, %{objects: [{0, "AVModbus"}, {1, "XIAO ESP32-C5"}, {2, "0.1.0"}]}} =
             Identification.answer(@basic, {:read_device_identification, :basic, 99})
  end
end
