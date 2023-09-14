defmodule BroadwayRabbitMQ.AmqpClient do
  @moduledoc false

  alias AMQP.{
    Connection,
    Channel,
    Basic,
    Queue
  }

  require Logger

  @behaviour BroadwayRabbitMQ.RabbitmqClient

  @connection_opts_schema [
    username: [type: :any],
    password: [type: :any],
    virtual_host: [type: :any],
    host: [type: :any],
    port: [type: :any],
    channel_max: [type: :any],
    frame_max: [type: :any],
    heartbeat: [type: :any],
    connection_timeout: [type: :any],
    ssl_options: [type: :any],
    client_properties: [type: :any],
    socket_options: [type: :any],
    auth_mechanisms: [type: :any]
  ]

  @binding_opts_schema [
    routing_key: [type: :any],
    arguments: [type: :any]
  ]

  @opts_schema [
    queue: [
      type: :string,
      required: true,
      doc: """
      The name of the queue. If `""`, then the queue name will
      be autogenerated by the server but for this to work you have to declare
      the queue through the `:declare` option.
      """
    ],
    connection: [
      type:
        {:or,
         [
           {:custom, __MODULE__, :__validate_amqp_uri__, []},
           {:custom, __MODULE__, :__validate_custom_pool__, []},
           keyword_list: @connection_opts_schema
         ]},
      default: [],
      doc: """
      Defines an AMQP URI (a string), a custom pool, or a set of options used by
      the RabbitMQ client to open the connection with the RabbitMQ broker.
      To use a custom pool, pass a `{:custom_pool, module, args}` tuple, see
      `BroadwayRabbitMQ.ChannelPool` for more information. If passing an AMQP URI
      or a list of options, this producer manages the AMQP connection instead.
      See `AMQP.Connection.open/1` for the full list of connection options.
      """
    ],
    qos: [
      type: :keyword_list,
      keys: [
        prefetch_size: [type: :non_neg_integer],
        prefetch_count: [type: :non_neg_integer, default: 50]
      ],
      default: [],
      doc: """
      Defines a set of prefetch options used by the RabbitMQ client.
      See `AMQP.Basic.qos/2` for the full list of options. Note that the
      `:global` option is not supported by Broadway since each producer holds only one
      channel per connection.
      """
    ],
    name: [
      type: {:or, [:string, {:in, [:undefined]}]},
      default: :undefined,
      doc: """
      The name of the AMQP connection to use.
      """
    ],
    metadata: [
      type: {:list, :atom},
      default: [],
      doc: """
      The list of AMQP metadata fields to copy (default: `[]`). Note
      that every `Broadway.Message` contains an `:amqp_channel` in its `metadata` field.
      See the "Metadata" section.
      """
    ],
    declare: [
      type: :keyword_list,
      keys: [
        durable: [type: :any, doc: false],
        auto_delete: [type: :any, doc: false],
        exclusive: [type: :any, doc: false],
        passive: [type: :any, doc: false],
        arguments: [type: :any, doc: false]
      ],
      doc: """
      A list of options used to declare the `:queue`. The
      queue is only declared (and possibly created if not already there) if this
      option is present and not `nil`. Note that if you use `""` as the queue
      name (which means that the queue name will be autogenerated on the server),
      then every producer stage will declare a different queue. If you want all
      producer stages to consume from the same queue, use a specific queue name.
      You can still declare the same queue as many times as you want because
      queue creation is idempotent (as long as you don't use the `passive: true`
      option). For the available options, see `AMQP.Queue.declare/3`, `:nowait` is not supported.
      """
    ],
    bindings: [
      type: {:list, {:custom, __MODULE__, :__validate_binding__, []}},
      default: [],
      doc: """
      A list of bindings for the `:queue`. This option
      allows you to bind the queue to one or more exchanges. Each binding is a tuple
      `{exchange_name, binding_options}` where so that the queue will be bound
      to `exchange_name` through `AMQP.Queue.bind/4` using `binding_options` as
      the options. Bindings are idempotent so you can bind the same queue to the
      same exchange multiple times.
      """
    ],
    merge_options: [
      type: {:fun, 1},
      doc: """
      A function that takes the index of the producer in the
      Broadway topology and returns a keyword list of options. The returned options
      are merged with the other options given to the producer. This option is useful
      to dynamically change options based on the index of the producer. For example,
      you can use this option to "shard" load between a few queues where a subset of
      the producer stages is connected to each queue, or to connect producers to
      different RabbitMQ nodes (for example through partitioning). Note that the options
      are evaluated every time a connection is established (for example, in case
      of disconnections). This means that you can also use this option to choose
      different options on every reconnections. This can be particularly useful
      if you have multiple RabbitMQ URLs: in that case, you can reconnect to a different
      URL every time you reconnect to RabbitMQ, which avoids the case where the
      producer tries to always reconnect to a URL that is down.
      """
    ],
    after_connect: [
      type: {:fun, 1},
      doc: """
      A function that takes the AMQP channel that the producer
      is connected to and can run arbitrary setup. This is useful for declaring
      complex RabbitMQ topologies with possibly multiple queues, bindings, or
      exchanges. RabbitMQ declarations are generally idempotent so running this
      function from all producer stages after every time they connect is likely
      fine. This function can return `:ok` if everything went well or `{:error, reason}`.
      In the error case then the producer will consider the connection failed and
      will try to reconnect later (same behavior as when the connection drops, for example).
      This function is run **before** the declaring and binding queues according to
      the `:declare` and `:bindings` options (described above).
      """
    ],
    consume_options: [
      type: :keyword_list,
      default: [],
      doc: """
      Options passed down to `AMQP.Basic.consume/4`. Not all options supported by
      `AMQP.Basic.consume/4` are available here as some options would conflict with
      the internal implementation of this producer.
      """,
      keys: [
        consumer_tag: [type: :string],
        no_local: [type: :boolean],
        no_ack: [type: :boolean],
        exclusive: [type: :boolean],
        arguments: [type: :any]
      ]
    ],
    broadway: [type: :any, doc: false]
  ]

  @doc false
  def __opts_schema__, do: @opts_schema

  @impl true
  def init(opts) do
    with {:ok, opts} <- validate_merge_opts(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, @opts_schema),
         :ok <- validate_declare_opts(opts[:declare], opts[:queue]) do
      {:ok,
       %{
         connection: Keyword.fetch!(opts, :connection),
         queue: Keyword.fetch!(opts, :queue),
         name: Keyword.fetch!(opts, :name),
         declare_opts: Keyword.get(opts, :declare, nil),
         bindings: Keyword.fetch!(opts, :bindings),
         qos: Keyword.fetch!(opts, :qos),
         metadata: Keyword.fetch!(opts, :metadata),
         consume_options: Keyword.fetch!(opts, :consume_options),
         after_connect: Keyword.get(opts, :after_connect, fn _channel -> :ok end)
       }}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  # This function should return "{:ok, channel}" if successful. If failing to setup a channel, a
  # connection, or if some network error happens at any point, this should close the connection it
  # opened.
  @impl true
  def setup_channel(config) do
    case get_channel(config) do
      {:ok, channel} ->
        with :ok <- call_after_connect(config, channel),
             :ok <- Basic.qos(channel, config.qos),
             {:ok, queue} <- maybe_declare_queue(channel, config.queue, config.declare_opts),
             :ok <- maybe_bind_queue(channel, queue, config.bindings) do
          {:ok, channel}
        else
          {:error, reason} ->
            # We don't terminate the caller process when something fails, but just reconnect
            # later. So if opening the connection works, but any other step fails (like opening
            # the channel), we need to close the connection, or otherwise we would leave the
            # connection open and leak it. In amqp_client, closing the connection also closes
            # everything related to it (like the channel, so we're good).
            close_channel(config, channel)
            {:error, reason}
        end

      error ->
        error
    end
  catch
    :exit, {:timeout, {:gen_server, :call, [amqp_conn_pid, :connect, timeout]}}
    when is_integer(timeout) ->
      # Make absolutely sure that this connection doesn't get established *after* the gen_server
      # call timeout triggers and becomes a zombie connection.
      true = Process.exit(amqp_conn_pid, :kill)
      {:error, :timeout}
  end

  defp get_channel(%{connection: {:custom_pool, module, args}}) do
    case module.checkout_channel(args) do
      {:ok, channel} ->
        true = Process.link(channel.pid)
        {:ok, channel}

      # TODO: use is_exception/1 when we depend on Elixir 1.11+
      {:error, %{__exception__: true} = exception} ->
        {:error, exception}

      other ->
        raise """
        expected #{Exception.format_mfa(module, :checkout_channel, 1)} to \
        return {:ok, AMQP.Channel.t()} or {:error, exception}, got: \
        #{inspect(other)}\
        """
    end
  end

  defp get_channel(config) do
    with {:ok, conn} <- open_connection_instrumented(config),
         # We need to link so that if our process crashes, the AMQP connection will go
         # down. We're trapping exits in the producer anyways so on our end this looks
         # like a monitor, pretty much.
         true = Process.link(conn.pid),
         {{:ok, chan}, _conn} <- {Channel.open(conn), conn} do
      {:ok, chan}
    else
      {:error, reason} ->
        {:error, reason}

      {{:error, reason}, conn} ->
        _ = Connection.close(conn)
        {:error, reason}
    end
  end

  defp close_channel(%{connection: {:custom_pool, module, args}}, channel) do
    case module.checkin_channel(args, channel) do
      :ok ->
        :ok

      # TODO: use is_exception/1 when we depend on Elixir 1.11+
      {:error, %{__exception__: true} = exception} ->
        Channel.close(channel)
        {:error, exception}

      other ->
        Channel.close(channel)

        raise """
        expected #{Exception.format_mfa(module, :checkin_channel, 1)} to \
        return :ok or {:error, exception}, got: \
        #{inspect(other)}\
        """
    end
  end

  defp close_channel(_config, channel) do
    Channel.close(channel)
    Process.unlink(channel.conn.pid)
    Connection.close(channel.conn)
  end

  defp open_connection_instrumented(config) do
    {name, config} = Map.pop(config, :name, :undefined)
    telemetry_meta = %{connection: config.connection, connection_name: name}

    :telemetry.span([:broadway_rabbitmq, :amqp, :open_connection], telemetry_meta, fn ->
      {Connection.open(config.connection, name), telemetry_meta}
    end)
  end

  defp call_after_connect(config, channel) do
    case config.after_connect.(channel) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        close_channel(config, channel)
        raise "unexpected return value from the :after_connect function: #{inspect(other)}"
    end
  end

  defp maybe_declare_queue(_channel, queue, _declare_opts = nil) do
    {:ok, queue}
  end

  defp maybe_declare_queue(channel, queue, declare_opts) do
    with {:ok, %{queue: queue}} <- Queue.declare(channel, queue, declare_opts) do
      {:ok, queue}
    end
  end

  defp maybe_bind_queue(_channel, _queue, _bindings = []) do
    :ok
  end

  defp maybe_bind_queue(channel, queue, [{exchange, opts} | bindings]) do
    case Queue.bind(channel, queue, exchange, opts) do
      :ok -> maybe_bind_queue(channel, queue, bindings)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ack(channel, delivery_tag) do
    :telemetry.span([:broadway_rabbitmq, :amqp, :ack], _meta = %{}, fn ->
      try do
        Basic.ack(channel, delivery_tag)
      catch
        :exit, {:noproc, _} -> {{:error, :noproc}, _meta = %{}}
      else
        result -> {result, _meta = %{}}
      end
    end)
  end

  @impl true
  def reject(channel, delivery_tag, opts) do
    :telemetry.span([:broadway_rabbitmq, :amqp, :reject], %{requeue: opts[:requeue]}, fn ->
      try do
        Basic.reject(channel, delivery_tag, opts)
      catch
        :exit, {:noproc, _} -> {{:error, :noproc}, _meta = %{}}
      else
        result -> {result, _meta = %{}}
      end
    end)
  end

  @impl true
  def consume(channel, %{queue: queue, consume_options: consume_options} = _config) do
    {:ok, consumer_tag} = Basic.consume(channel, queue, _consumer_pid = self(), consume_options)
    consumer_tag
  end

  @impl true
  def cancel(channel, consumer_tag) do
    Basic.cancel(channel, consumer_tag)
  end

  @impl true
  def close_connection(config, channel) do
    if Process.alive?(channel.pid) do
      close_channel(config, channel)
    else
      :ok
    end
  end

  defp validate_merge_opts(opts) do
    case Keyword.fetch(opts, :merge_options) do
      {:ok, fun} when is_function(fun, 1) ->
        index = opts[:broadway][:index] || raise "missing broadway index"
        merge_opts = fun.(index)

        if Keyword.keyword?(merge_opts) do
          {:ok, Keyword.merge(opts, merge_opts)}
        else
          message =
            "The :merge_options function should return a keyword list, " <>
              "got: #{inspect(merge_opts)}"

          {:error, message}
        end

      {:ok, other} ->
        {:error, ":merge_options must be a function with arity 1, got: #{inspect(other)}"}

      :error ->
        {:ok, opts}
    end
  end

  def __validate_amqp_uri__(uri) when is_binary(uri) do
    case uri |> to_charlist() |> :amqp_uri.parse() do
      {:ok, _amqp_params} -> {:ok, uri}
      {:error, reason} -> {:error, "failed parsing AMQP URI: #{inspect(reason)}"}
    end
  end

  def __validate_amqp_uri__(_value), do: {:error, "failed parsing AMQP URI."}

  defp validate_declare_opts(declare_opts, queue) do
    if queue == "" and is_nil(declare_opts) do
      {:error, "can't use \"\" (server autogenerate) as the queue name without the :declare"}
    else
      :ok
    end
  end

  def __validate_binding__({exchange, binding_opts}) when is_binary(exchange) do
    case NimbleOptions.validate(binding_opts, @binding_opts_schema) do
      {:ok, validated_binding_opts} -> {:ok, {exchange, validated_binding_opts}}
      {:error, %NimbleOptions.ValidationError{} = reason} -> {:error, Exception.message(reason)}
    end
  end

  def __validate_binding__(other) do
    {:error, "expected binding to be a {exchange, opts} tuple, got: #{inspect(other)}"}
  end

  def __validate_custom_pool__({:custom_pool, module, _options} = value) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         behaviours =
           module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
         true <- Enum.any?(behaviours, &(&1 == BroadwayRabbitMQ.ChannelPool)) do
      {:ok, value}
    else
      _error ->
        {:error,
         "#{inspect(module)} must be a module that implements BroadwayRabbitMQ.ChannelPool behaviour"}
    end
  end

  def __validate_custom_pool__(_value), do: {:error, "invalid custom_pool option"}
end
