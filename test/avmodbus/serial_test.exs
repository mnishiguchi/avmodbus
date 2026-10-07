defmodule AVModbus.SerialTest do
  use ExUnit.Case, async: true

  alias AVModbus.Serial

  test "strips an adapter echo in one chunk" do
    assert Serial.strip_echo(<<1, 2, 3>>, <<1, 2, 3, 9>>) == {<<>>, <<9>>}
  end

  test "strips an adapter echo across chunks" do
    assert Serial.strip_echo(<<1, 2, 3>>, <<1>>) == {<<2, 3>>, <<>>}
    assert Serial.strip_echo(<<2, 3>>, <<2, 3, 4>>) == {<<>>, <<4>>}
  end

  test "preserves data as soon as it differs from the expected echo" do
    assert Serial.strip_echo(<<1, 2, 3>>, <<7, 8>>) == {<<>>, <<7, 8>>}
    assert Serial.strip_echo(<<>>, <<1, 2>>) == {<<>>, <<1, 2>>}
  end
end
