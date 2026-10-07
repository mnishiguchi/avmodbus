defmodule AVModbus.Server.ASCII do
  @moduledoc """
  AtomVM UART または injected serial transport 上で動作する Modbus ASCII server です。

  request policy、diagnostics、lifecycle recovery、UART ownership は
  `AVModbus.Server.RTU` と共有し、ASCII/LRC framing と delimiter behavior を選択します。
  """

  alias AVModbus.Server
  alias AVModbus.Server.RTU, as: SerialServer

  @type server :: pid() | atom()
  @type t :: {__MODULE__, server()}
  @type option :: SerialServer.option()

  @doc false
  def child_spec(options) when is_list(options) do
    %{
      id: option(options, :name, __MODULE__),
      start: {__MODULE__, :start_supervised, [options]}
    }
  end

  @doc false
  def start_supervised(options) when is_list(options) do
    with {:ok, handler, server_options} <- take_handler(options),
         {:ok, {__MODULE__, pid}} <- start_link(handler, server_options) do
      {:ok, pid}
    end
  end

  def start_supervised(_options), do: {:error, :invalid_options}

  @doc "configured UART を開いて ASCII server を起動します。"
  @spec start_link(Server.handler(), [option()]) :: {:ok, t()} | {:error, term()}
  def start_link(handler, options \\ [])

  def start_link(handler, options) when is_list(options) do
    translate(SerialServer.start_link(handler, [{:mode, :ascii} | options]))
  end

  def start_link(_handler, _options), do: {:error, :invalid_options}

  @doc false
  @spec start_link(module(), Server.handler(), [option()]) :: {:ok, t()} | {:error, term()}
  def start_link(transport, handler, options) when is_atom(transport) and is_list(options) do
    translate(SerialServer.start_link(transport, handler, [{:mode, :ascii} | options]))
  end

  def start_link(_transport, _handler, _options), do: {:error, :invalid_options}

  @doc "open 済み transport handle 上で ASCII server を起動します。"
  @spec start_link(module(), term(), Server.handler(), [option()]) ::
          {:ok, t()} | {:error, term()}
  def start_link(transport, uart, handler, options)
      when is_atom(transport) and is_list(options) do
    translate(SerialServer.start_link(transport, uart, handler, [{:mode, :ascii} | options]))
  end

  def start_link(_transport, _uart, _handler, _options), do: {:error, :invalid_options}

  @doc "ASCII server を停止します。"
  @spec close(t() | server()) :: :ok
  def close({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.stop(server)

  def close(server) when is_pid(server) or is_atom(server), do: :gen_server.stop(server)

  @doc "ASCII server を停止します。"
  @spec stop(t() | server()) :: :ok
  def stop(server), do: close(server)

  @doc "UART connection state を返します。"
  @spec status(t() | server()) :: :connected | {:disconnected, term()}
  def status({__MODULE__, server}) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  def status(server) when is_pid(server) or is_atom(server),
    do: :gen_server.call(server, :status)

  defp translate({:ok, {SerialServer, pid}}), do: {:ok, {__MODULE__, pid}}
  defp translate({:error, _reason} = error), do: error

  defp option([], _key, default), do: default
  defp option([{key, value} | _rest], key, _default), do: value
  defp option([_option | rest], key, default), do: option(rest, key, default)

  defp take_handler(options), do: take_handler(options, [])
  defp take_handler([], _rest), do: {:error, :missing_handler_option}

  defp take_handler([{:handler, handler} | rest], reversed),
    do: {:ok, handler, reverse_append(reversed, rest)}

  defp take_handler([option | rest], reversed),
    do: take_handler(rest, [option | reversed])

  defp reverse_append([], tail), do: tail
  defp reverse_append([value | rest], tail), do: reverse_append(rest, [value | tail])
end
