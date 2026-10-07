defmodule AVModbus.StartupValidationTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, Memory}
  alias AVModbus.Server.ASCII, as: ASCIIServer
  alias AVModbus.Server.RTU, as: RTUServer
  alias AVModbus.Server.TCP, as: TCPServer

  test "all server transports reject invalid handlers before opening a transport" do
    assert TCPServer.start_link(:invalid, port: 0) == {:error, :invalid_handler}
    assert RTUServer.start_link(:invalid, units: [1]) == {:error, :invalid_handler}
    assert ASCIIServer.start_link(:invalid, units: [1]) == {:error, :invalid_handler}

    assert TCPServer.start_link({123, :argument}, port: 0) == {:error, :invalid_handler}
    assert RTUServer.start_link({123, :argument}, units: [1]) == {:error, :invalid_handler}
    assert ASCIIServer.start_link({123, :argument}, units: [1]) == {:error, :invalid_handler}
  end

  test "supervision entry points return stable errors for malformed options" do
    assert Client.start_supervised(:invalid) == {:error, :invalid_options}
    assert TCPServer.start_supervised(:invalid) == {:error, :invalid_options}
    assert RTUServer.start_supervised(:invalid) == {:error, :invalid_options}
    assert ASCIIServer.start_supervised(:invalid) == {:error, :invalid_options}
  end

  test "direct startup entry points return stable option and name errors" do
    handler = fn _unit_id, _request -> :ok end

    assert TCPServer.start_link(handler, :invalid) == {:error, :invalid_options}
    assert RTUServer.start_link(handler, :invalid) == {:error, :invalid_options}
    assert ASCIIServer.start_link(handler, :invalid) == {:error, :invalid_options}
    assert Client.start_link(:transport, :uart, :invalid) == {:error, :invalid_options}

    assert Memory.start_link(name: "invalid") == {:error, :invalid_name_option}
  end

  test "TLS requests fail closed with a stable unsupported error" do
    handler = fn _unit_id, _request -> :ok end

    assert Client.start_link(tls: "127.0.0.1") == {:error, :tls_not_supported}

    assert Client.start_link(tcp: "127.0.0.1", ssl: [verify: :verify_none]) ==
             {:error, :tls_not_supported}

    assert TCPServer.start_link(handler, ssl: []) == {:error, :tls_not_supported}
    assert TCPServer.start_supervised(handler: handler, tls: true) == {:error, :tls_not_supported}
  end
end
