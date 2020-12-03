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
    no_wait: [type: :any],
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
      type: {:custom, __MODULE__, :__validate_connection_options__, []},
      default: [],
      doc: """
      Defines an AMQP URI or a set of options used by
      the RabbitMQ client to open the connection with the RabbitMQ broker. See
      `AMQP.Connection.open/1` for the full list of options.
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
      type: {:custom, __MODULE__, :__validate_connection_name__, []},
      default: :undefined,
      doc: """
      The name of the AMQP connection to use.
      """
    ],
    backoff_min: [
      type: :non_neg_integer,
      doc: """
      The minimum backoff interval (default: `1_000`).
      """
    ],
    backoff_max: [
      type: :non_neg_integer,
      doc: """
      The maximum backoff interval (default: `30_000`).
      """
    ],
    backoff_type: [
      type: {:in, [:exp, :rand, :rand_exp, :stop]},
      doc: """
      The backoff strategy. `:stop` for no backoff and
      to stop, `:exp` for exponential, `:rand` for random and `:rand_exp` for
      random exponential (default: `:rand_exp`).
      """
    ],
    metadata: [
      type: {:custom, __MODULE__, :__validate_metadata__, []},
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
        no_wait: [type: :any, doc: false],
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
      option). For the available options, see `AMQP.Queue.declare/3`.
      """
    ],
    bindings: [
      type: {:custom, __MODULE__, :__validate_bindings__, []},
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
    {name, config} = Map.pop(config, :name, :undefined)

    telemetry_meta = %{connection: config.connection, connection_name: name}

    case :telemetry.span([:broadway_rabbitmq, :amqp, :open_connection], telemetry_meta, fn ->
           {Connection.open(config.connection, name), telemetry_meta}
         end) do
      {:ok, conn} ->
        # We need to link so that if our process crashes, the AMQP connection will go
        # down. We're trapping exits in the producer anyways so on our end this looks
        # like a monitor, pretty much.
        true = Process.link(conn.pid)

        with {:ok, channel} <- Channel.open(conn),
             :ok <- call_after_connect(config, channel),
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
            _ = Connection.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, {:timeout, {:gen_server, :call, [amqp_conn_pid, :connect, timeout]}}
    when is_integer(timeout) ->
      # Make absolutely sure that this connection doesn't get established *after* the gen_server
      # call timeout triggers and becomes a zombie connection.
      true = Process.exit(amqp_conn_pid, :kill)
      {:error, :timeout}
  end

  defp call_after_connect(config, channel) do
    case config.after_connect.(channel) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
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
      {Basic.ack(channel, delivery_tag), _meta = %{}}
    end)
  end

  @impl true
  def reject(channel, delivery_tag, opts) do
    :telemetry.span([:broadway_rabbitmq, :amqp, :reject], %{requeue: opts[:requeue]}, fn ->
      {Basic.reject(channel, delivery_tag, opts), _meta = %{}}
    end)
  end

  @impl true
  def consume(channel, config) do
    {:ok, consumer_tag} = Basic.consume(channel, config.queue)
    consumer_tag
  end

  @impl true
  def cancel(channel, consumer_tag) do
    Basic.cancel(channel, consumer_tag)
  end

  @impl true
  def close_connection(conn) do
    if Process.alive?(conn.pid) do
      Connection.close(conn)
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

  def __validate_metadata__(value) do
    if is_list(value) and Enum.all?(value, &is_atom/1) do
      {:ok, value}
    else
      {:error, "expected :metadata to be a list of atoms, got: #{inspect(value)}"}
    end
  end

  def __validate_connection_name__(value) do
    if is_binary(value) or value == :undefined do
      {:ok, value}
    else
      {:error, "expected :name to be a string or the atom :undefined, got: #{inspect(value)}"}
    end
  end

  def __validate_connection_options__(uri) when is_binary(uri) do
    case uri |> to_charlist() |> :amqp_uri.parse() do
      {:ok, _amqp_params} -> {:ok, uri}
      {:error, reason} -> {:error, "Failed parsing AMQP URI: #{inspect(reason)}"}
    end
  end

  def __validate_connection_options__(opts) when is_list(opts) do
    with {:error, %NimbleOptions.ValidationError{} = error} <-
           NimbleOptions.validate(opts, @connection_opts_schema),
         do: {:error, Exception.message(error) <> " (in option :connection)"}
  end

  def __validate_connection_options__(other) do
    {:error, "expected :connection to be a URI or a keyword list, got: #{inspect(other)}"}
  end

  defp validate_declare_opts(declare_opts, queue) do
    if queue == "" and is_nil(declare_opts) do
      {:error, "can't use \"\" (server autogenerate) as the queue name without the :declare"}
    else
      :ok
    end
  end

  def __validate_bindings__(value) when is_list(value) do
    Enum.each(value, fn
      {exchange, binding_opts} when is_binary(exchange) ->
        case NimbleOptions.validate(binding_opts, @binding_opts_schema) do
          {:ok, _bindings_opts} ->
            :ok

          {:error, %NimbleOptions.ValidationError{} = reason} ->
            throw({:error, Exception.message(reason)})
        end

      {other, _opts} ->
        throw({:error, "the exchange in a binding should be a string, got: #{inspect(other)}"})

      other ->
        message =
          "expected :bindings to be a list of bindings ({exchange, bind_options} tuples), " <>
            "got: #{inspect(other)}"

        throw({:error, message})
    end)

    {:ok, value}
  catch
    :throw, {:error, message} -> {:error, message}
  end

  def __validate_bindings__(other) do
    {:error, "expected bindings to be a list of {exchange, opts} tuples, got: #{inspect(other)}"}
  end
end
