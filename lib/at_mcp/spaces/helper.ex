defmodule AtMcp.Spaces.Helper do
  @moduledoc """
  The one process responsible for the Spaces helper, `at_mcp-spaces`: a Node
  program shipped in the release (`priv/spaces_helper/at_mcp-spaces.mjs`,
  built from `spaces_helper/`) that wraps Bluesky's `@atproto/oauth-client`
  and `@atproto/lex-space`.

  The helper holds every account's OAuth session (its refresh token stays
  there) and does everything Spaces needs: the pass exchange, request
  signing, MAC checks and sync. This process starts it as a port, speaks
  JSON-RPC 2.0 to it, one JSON object per line, and stops it by closing its
  input when it stops itself. A helper that exits fails the calls waiting on
  it as indeterminate, and the next call starts a new one.

  Spaces are optional. With `AT_MCP_SPACES=false`, or with no `node` (22 or
  later) on the path or at `AT_MCP_NODE`, or no built helper in the release,
  `available/0` answers why, and every Spaces call is refused with
  `spaces_unavailable` before anything is sent. Everything else AtMcp does
  works the same without it.

  The helper's own state (sessions, sync copies) is under `spaces/` in the
  state directory, 0600, like AtMcp's other private files.
  """

  use GenServer

  require Logger

  alias AtMcp.Effects.Failure

  @protocol 1
  @call_timeout 60_000
  # A JSON-RPC line may carry a whole page of records.
  @max_line 64 * 1024 * 1024

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "`:ok`, or `{:error, reason}` saying why Spaces are switched off."
  def available(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(server, :available)
    end
  end

  # The helper's methods that change nothing at any server.
  @reads ~w(key.public oauth.status space.get space.list space.authorize space.records.get
            space.records.list space.writers space.all space.members.list)

  @doc """
  Calls `method` with `params` (a map with string or atom keys). Answers
  `{:ok, result}` with the result's keys as strings, or `{:error,
  %AtMcp.Effects.Failure{}}` in AtMcp's three kinds, with the helper's code
  as `detail`.
  """
  def call(method, params, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    case GenServer.whereis(server) do
      nil ->
        {:error, unavailable(:not_started)}

      _pid ->
        case send_call(server, method, params, timeout) do
          # A read that met the helper as it stopped is asked once more, of
          # the helper started in its place: a read changes nothing. A write
          # is not, since it may have happened.
          {:error, %Failure{detail: :spaces_helper_exited}} when method in @reads ->
            send_call(server, method, params, timeout)

          result ->
            result
        end
    end
  end

  defp send_call(server, method, params, timeout) do
    GenServer.call(server, {:call, method, params, timeout}, timeout + 5_000)
  catch
    :exit, {:timeout, _} ->
      {:error, Failure.new(:indeterminate, detail: :spaces_helper_timeout)}
  end

  @doc "Where the helper script is in this release."
  def script, do: Application.app_dir(:at_mcp, ["priv", "spaces_helper", "at_mcp-spaces.mjs"])

  @doc false
  def unavailable(reason),
    do:
      Failure.new(:refused,
        detail: :spaces_unavailable,
        message: "Spaces are not available in this installation: #{describe(reason)}"
      )

  defp describe(:disabled), do: "AT_MCP_SPACES is false"
  defp describe(:no_node), do: "no node executable was found (set AT_MCP_NODE, Node 22 or later)"
  defp describe({:old_node, v}), do: "node #{v} is too old; the helper needs Node 22 or later"
  defp describe(:no_script), do: "the release has no built Spaces helper"
  defp describe(:not_started), do: "the Spaces helper is not running"
  defp describe({:init_failed, why}), do: "the Spaces helper did not start (#{inspect(why)})"
  defp describe(other), do: inspect(other)

  # --- server ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      opts: opts,
      port: nil,
      buffer: [],
      next_id: 1,
      pending: %{},
      status: :starting
    }

    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state) do
    status = check(state.opts)

    case status do
      :ok -> :ok
      {:error, reason} -> Logger.info("Spaces are off: #{describe(reason)}")
    end

    {:noreply, %{state | status: status}}
  end

  @doc false
  # The helper's OS process, for tests that stop it (nil when none runs).
  def os_pid(server \\ __MODULE__), do: GenServer.call(server, :os_pid)

  @impl true
  def handle_call(:available, _from, state), do: {:reply, state.status, state}

  def handle_call(:os_pid, _from, %{port: port} = state) when is_port(port),
    do: {:reply, port |> Port.info(:os_pid) |> elem(1), state}

  def handle_call(:os_pid, _from, state), do: {:reply, nil, state}

  def handle_call(
        {:call, _method, _params, _timeout},
        _from,
        %{status: {:error, reason}} = state
      ),
      do: {:reply, {:error, unavailable(reason)}, state}

  def handle_call({:call, method, params, timeout}, from, state) do
    case ensure_port(state) do
      {:ok, state} -> {:noreply, send_call(state, method, params, from, timeout)}
      {:error, reason, state} -> {:reply, {:error, unavailable({:init_failed, reason})}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary(Enum.reverse([chunk | state.buffer]))
    {:noreply, handle_line(%{state | buffer: []}, line)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: [chunk | state.buffer]}}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("the Spaces helper exited with status #{status}")
    {:noreply, fail_pending(%{state | port: nil, buffer: []}, :spaces_helper_exited)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, fail_pending(%{state | port: nil, buffer: []}, :spaces_helper_exited)}

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, pending} ->
        GenServer.reply(
          from,
          {:error, Failure.new(:indeterminate, detail: :spaces_helper_timeout)}
        )

        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    # Closing its input ends the helper.
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- the port ---

  defp check(opts) do
    cond do
      not Keyword.get(opts, :enabled, Application.get_env(:at_mcp, :spaces_enabled, true)) ->
        {:error, :disabled}

      is_nil(node_path(opts)) ->
        {:error, :no_node}

      not File.regular?(Keyword.get(opts, :script, script())) ->
        {:error, :no_script}

      true ->
        node_version(node_path(opts))
    end
  end

  defp node_path(opts) do
    case Keyword.get(opts, :node, Application.get_env(:at_mcp, :spaces_node)) do
      nil -> System.find_executable("node")
      path -> if File.regular?(path), do: path, else: System.find_executable(path)
    end
  end

  defp node_version(node) do
    case System.cmd(node, ["--version"], stderr_to_stdout: true) do
      {"v" <> version, 0} ->
        version = String.trim(version)

        case Integer.parse(version) do
          {major, _} when major >= 22 -> :ok
          _ -> {:error, {:old_node, version}}
        end

      _ ->
        {:error, :no_node}
    end
  rescue
    _ -> {:error, :no_node}
  end

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    node = node_path(state.opts)
    script = Keyword.get(state.opts, :script, script())

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, @max_line},
        {:args, [script]}
      ])

    state = %{state | port: port}
    config = init_config(state.opts)

    # `init` is answered before any other call is sent, so a call never runs
    # on a helper that has not been configured.
    case sync_call(state, "init", config) do
      {:ok, %{"protocol" => @protocol}, state} ->
        {:ok, state}

      {:ok, other, state} ->
        {:error, {:protocol, other}, close(state)}

      {:error, reason, state} ->
        {:error, reason, close(state)}
    end
  end

  defp close(%{port: port} = state) do
    if is_port(port), do: Port.close(port)
    %{state | port: nil}
  catch
    _, _ -> %{state | port: nil}
  end

  defp init_config(opts) do
    state_dir =
      Keyword.get(opts, :state_dir, Path.join(AtMcp.Inbound.Store.default_dir(), "spaces"))

    File.mkdir_p!(state_dir)
    File.chmod!(state_dir, 0o700)
    plc = Keyword.get(opts, :plc_url, Application.get_env(:at_mcp, :plc_url))

    handle_resolver =
      Keyword.get(opts, :handle_resolver, Application.get_env(:at_mcp, :handle_resolver))

    %{
      stateDir: state_dir,
      userAgent: AtMcp.UserAgent.value(),
      inboxReaders: Keyword.get(opts, :inbox_readers, AtMcp.Spaces.inbox_readers()),
      allowHttp:
        Keyword.get(opts, :allow_http, Application.get_env(:at_mcp, :spaces_allow_http, false))
    }
    |> put_present(:plcDirectoryUrl, plc)
    |> put_present(:handleResolver, handle_resolver)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp sync_call(state, method, params) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    Port.command(state.port, encode(id, method, params))
    await_reply(state, id, [])
  end

  defp await_reply(%{port: port} = state, id, buffer) do
    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await_reply(state, id, [chunk | buffer])

      {^port, {:data, {:eol, chunk}}} ->
        line = IO.iodata_to_binary(Enum.reverse([chunk | buffer]))

        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result, state}
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, {:helper, error}, state}
          {:ok, %{"method" => "log", "params" => p}} -> log(p) && await_reply(state, id, [])
          _other -> await_reply(state, id, [])
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}, %{state | port: nil}}
    after
      15_000 -> {:error, :init_timeout, state}
    end
  end

  defp send_call(state, method, params, from, timeout) do
    id = state.next_id
    Port.command(state.port, encode(id, method, params))
    timer = Process.send_after(self(), {:timeout, id}, timeout)
    %{state | next_id: id + 1, pending: Map.put(state.pending, id, {from, timer})}
  end

  defp encode(id, method, params),
    do: [Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}), "\n"]

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"method" => "log", "params" => params}} ->
        log(params)
        state

      {:ok, %{"id" => id} = message} when is_map_key(state.pending, id) ->
        {{from, timer}, pending} = Map.pop(state.pending, id)
        Process.cancel_timer(timer)
        GenServer.reply(from, answer(message))
        %{state | pending: pending}

      _other ->
        Logger.warning("the Spaces helper wrote a line AtMcp could not read")
        state
    end
  end

  defp answer(%{"result" => result}), do: {:ok, result}
  defp answer(%{"error" => error}), do: {:error, failure(error)}
  defp answer(_), do: {:error, Failure.new(:indeterminate, detail: :spaces_helper_unreadable)}

  @doc false
  # The helper names its failures in AtMcp's own kinds; anything else, a
  # protocol error included, is indeterminate.
  def failure(%{"data" => %{"class" => class} = data} = error)
      when class in ["refused", "auth_refused", "indeterminate"] do
    Failure.new(String.to_existing_atom(class),
      detail: data["code"],
      status: data["status"],
      message: error["message"]
    )
  end

  def failure(error),
    do: Failure.new(:indeterminate, detail: :spaces_helper_error, message: error["message"])

  defp fail_pending(state, why) do
    for {_id, {from, timer}} <- state.pending do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, Failure.new(:indeterminate, detail: why)})
    end

    %{state | pending: %{}}
  end

  defp log(%{"level" => level, "message" => message} = params) do
    meta =
      params |> Map.drop(["level", "message"]) |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    text = "Spaces helper: #{message}" <> if(meta == "", do: "", else: " (#{meta})")

    case level do
      "error" -> Logger.error(text)
      "warning" -> Logger.warning(text)
      "debug" -> Logger.debug(text)
      _ -> Logger.info(text)
    end

    true
  end

  defp log(_), do: true
end
