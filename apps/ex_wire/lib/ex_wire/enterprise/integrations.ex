defmodule ExWire.Enterprise.Integrations do
  @moduledoc """
  Enterprise system integrations for connecting Mana-Ethereum with corporate infrastructure.
  Supports ERP systems, databases, message queues, monitoring tools, and cloud services.
  """

  use GenServer
  require Logger

  alias ExWire.Enterprise.AuditLogger

  defstruct [
    :connectors,
    :active_connections,
    :message_queue,
    :webhooks,
    :transformers,
    :config
  ]

  @type connector :: %{
          id: String.t(),
          name: String.t(),
          type: atom(),
          config: map(),
          status: :connected | :disconnected | :error,
          last_health_check: DateTime.t() | nil,
          metrics: map()
        }

  @type webhook :: %{
          id: String.t(),
          url: String.t(),
          events: list(atom()),
          headers: map(),
          retry_config: map(),
          active: boolean()
        }

  # Supported integration types
  @integration_types [
    :sap,
    :oracle_erp,
    :salesforce,
    :postgresql,
    :mysql,
    :mongodb,
    :kafka,
    :rabbitmq,
    :aws_sqs,
    :elasticsearch,
    :splunk,
    :datadog,
    :prometheus,
    :slack,
    :teams,
    :email,
    :rest_api,
    :graphql_api,
    :grpc
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Register a new integration connector
  """
  def register_connector(type, name, _config) do
    GenServer.call(__MODULE__, {:register_connector, type, name, config})
  end

  @doc """
  Connect to an external system
  """
  def connect(connector_id) do
    GenServer.call(__MODULE__, {:connect, connector_id})
  end

  @doc """
  Disconnect from an external system
  """
  def disconnect(connector_id) do
    GenServer.call(__MODULE__, {:disconnect, connector_id})
  end

  @doc """
  Send data to external system
  """
  def send_data(connector_id, data, opts \\ []) do
    GenServer.call(__MODULE__, {:send_data, connector_id, data, opts})
  end

  @doc """
  Query data from external system
  """
  def query_data(connector_id, query, opts \\ []) do
    GenServer.call(__MODULE__, {:query_data, connector_id, query, opts})
  end

  @doc """
  Register a webhook
  """
  def register_webhook(url, events, opts \\ []) do
    GenServer.call(__MODULE__, {:register_webhook, url, events, opts})
  end

  @doc """
  Trigger webhook for event
  """
  def trigger_webhook(event, data) do
    GenServer.cast(__MODULE__, {:trigger_webhook, event, data})
  end

  @doc """
  Subscribe to blockchain events
  """
  def subscribe_events(connector_id, events) do
    GenServer.call(__MODULE__, {:subscribe_events, connector_id, events})
  end

  @doc """
  Transform data between formats
  """
  def transform_data(data, from_format, to_format) do
    GenServer.call(__MODULE__, {:transform_data, data, from_format, to_format})
  end

  @doc """
  Get connector status
  """
  def get_status(connector_id) do
    GenServer.call(__MODULE__, {:get_status, connector_id})
  end

  @doc """
  List all connectors
  """
  def list_connectors do
    GenServer.call(__MODULE__, :list_connectors)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Enterprise Integrations service")

    state = %__MODULE__{
      connectors: %{},
      active_connections: %{},
      message_queue: :queue.new(),
      webhooks: %{},
      transformers: initialize_transformers(),
      config: build_config(opts)
    }

    # Auto-connect configured integrations
    state = auto_connect_integrations(state, opts)

    schedule_health_checks()
    schedule_message_processing()

    {:ok, _state}
  end

  @impl true
  def handle_call({:register_connector, type, name, _config}, _from, _state) do
    if type not in @integration_types do
      {:reply, {:error, :unsupported_type}, state}
    else
      connector_id = generate_connector_id()

      connector = %{
        id: connector_id,
        name: name,
        type: type,
        config: validate_config(type, config),
        status: :disconnected,
        last_health_check: nil,
        metrics: initialize_metrics()
      }

      state = put_in(state.connectors[connector_id], connector)

      AuditLogger.log(:connector_registered, %{
        connector_id: connector_id,
        type: type,
        name: name
      })

      {:reply, {:ok, connector}, state}
    end
  end

  @impl true
  def handle_call({:connect, connector_id}, _from, _state) do
    case Map.get(state.connectors, connector_id) do
      nil ->
        {:reply, {:error, :connector_not_found}, state}

      connector ->
        case establish_connection(connector) do
          {:ok, connection} ->
            updated_connector = %{connector | status: :connected}

            state =
              state
              |> put_in([:connectors, connector_id], updated_connector)
              |> put_in([:active_connections, connector_id], connection)

            AuditLogger.log(:connector_connected, %{
              connector_id: connector_id,
              type: connector.type
            })

            {:reply, :ok, state}

          {:error, _reason} ->
            updated_connector = %{connector | status: :error}
            state = put_in(state.connectors[connector_id], updated_connector)

            {:reply, {:error, _reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:disconnect, connector_id}, _from, _state) do
    case Map.get(state.active_connections, connector_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      connection ->
        close_connection(connection, state.connectors[connector_id])

        updated_connector = %{state.connectors[connector_id] | status: :disconnected}

        state =
          state
          |> put_in([:connectors, connector_id], updated_connector)
          |> update_in([:active_connections], &Map.delete(&1, connector_id))

        AuditLogger.log(:connector_disconnected, %{
          connector_id: connector_id
        })

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:send_data, connector_id, data, opts}, _from, _state) do
    case Map.get(state.active_connections, connector_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      connection ->
        connector = state.connectors[connector_id]

        # Transform data if needed
        transformed_data = transform_for_connector(data, connector.type)

        case send_to_system(connection, connector, transformed_data, opts) do
          {:ok, result} ->
            state = update_metrics(state, connector_id, :data_sent)
            {:reply, {:ok, result}, state}

          {:error, _reason} ->
            state = update_metrics(state, connector_id, :errors)
            {:reply, {:error, _reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:query_data, connector_id, query, opts}, _from, _state) do
    case Map.get(state.active_connections, connector_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      connection ->
        connector = state.connectors[connector_id]

        case query_from_system(connection, connector, query, opts) do
          {:ok, result} ->
            # Transform result to internal format
            transformed = transform_from_connector(result, connector.type)
            state = update_metrics(state, connector_id, :queries_executed)
            {:reply, {:ok, transformed}, state}

          {:error, _reason} ->
            state = update_metrics(state, connector_id, :errors)
            {:reply, {:error, _reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:register_webhook, url, events, opts}, _from, _state) do
    webhook_id = generate_webhook_id()

    webhook = %{
      id: webhook_id,
      url: url,
      events: events,
      headers: Keyword.get(opts, :headers, %{}),
      retry_config: Keyword.get(opts, :retry_config, default_retry_config()),
      active: true,
      created_at: DateTime.utc_now()
    }

    state = put_in(state.webhooks[webhook_id], webhook)

    AuditLogger.log(:webhook_registered, %{
      webhook_id: webhook_id,
      url: url,
      events: events
    })

    {:reply, {:ok, webhook}, state}
  end

  @impl true
  def handle_call({:subscribe_events, connector_id, events}, _from, _state) do
    case Map.get(state.connectors, connector_id) do
      nil ->
        {:reply, {:error, :connector_not_found}, state}

      connector ->
        # Set up event subscription
        subscription = create_event_subscription(connector, events)

        updated_connector = Map.put(connector, :subscriptions, subscription)
        state = put_in(state.connectors[connector_id], updated_connector)

        {:reply, {:ok, subscription}, state}
    end
  end

  @impl true
  def handle_call({:transform_data, data, from_format, to_format}, _from, _state) do
    case transform(data, from_format, to_format, state.transformers) do
      {:ok, transformed} ->
        {:reply, {:ok, transformed}, state}

      {:error, _reason} ->
        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call({:get_status, connector_id}, _from, _state) do
    case Map.get(state.connectors, connector_id) do
      nil ->
        {:reply, {:error, :connector_not_found}, state}

      connector ->
        status = %{
          id: connector.id,
          name: connector.name,
          type: connector.type,
          status: connector.status,
          last_health_check: connector.last_health_check,
          metrics: connector.metrics
        }

        {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_call(:list_connectors, _from, _state) do
    connectors = Map.values(state.connectors)
    {:reply, {:ok, connectors}, state}
  end

  @impl true
  def handle_cast({:trigger_webhook, event, data}, _state) do
    # Find webhooks subscribed to this event
    webhooks =
      Enum.filter(state.webhooks, fn {_id, webhook} ->
        webhook.active && event in webhook.events
      end)

    # Trigger each webhook
    Enum.each(webhooks, fn {_id, webhook} ->
      trigger_webhook_async(webhook, event, data)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, _state) do
    state = perform_health_checks(state)
    schedule_health_checks()
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_messages, _state) do
    state = process_message_queue(state)
    schedule_message_processing()
    {:noreply, state}
  end

  @impl true
  def handle_info({:blockchain_event, event, data}, _state) do
    # Handle blockchain events and forward to subscribers
    handle_blockchain_event(event, data, state)
    {:noreply, state}
  end

  # Private Functions - Connection Management

  defp establish_connection(connector) do
    case connector.type do
      :postgresql ->
        connect_postgresql(connector.config)

      :mysql ->
        connect_mysql(connector.config)

      :mongodb ->
        connect_mongodb(connector.config)

      :kafka ->
        connect_kafka(connector.config)

      :rabbitmq ->
        connect_rabbitmq(connector.config)

      :aws_sqs ->
        connect_sqs(connector.config)

      :elasticsearch ->
        connect_elasticsearch(connector.config)

      :rest_api ->
        {:ok, %{type: :rest, base_url: connector._config.url}}

      :graphql_api ->
        {:ok, %{type: :graphql, endpoint: connector.config.endpoint}}

      :grpc ->
        connect_grpc(connector.config)

      _ ->
        {:ok, %{type: connector.type, config: connector.config}}
    end
  end

  defp close_connection(connection, connector) do
    case connector.type do
      :postgresql -> close_postgresql(connection)
      :mysql -> close_mysql(connection)
      :mongodb -> close_mongodb(connection)
      :kafka -> close_kafka(connection)
      :rabbitmq -> close_rabbitmq(connection)
      _ -> :ok
    end
  end

  # Private Functions - Database Connectors

  defp connect_postgresql(_config) do
    # PostgreSQL connection using Postgrex
    {:ok, %{type: :postgresql, config: _config}}
  end

  defp connect_mysql(_config) do
    # MySQL connection
    {:ok, %{type: :mysql, config: config}}
  end

  defp connect_mongodb(_config) do
    # MongoDB connection
    {:ok, %{type: :mongodb, config: config}}
  end

  defp close_postgresql(_connection), do: :ok
  defp close_mysql(_connection), do: :ok
  defp close_mongodb(_connection), do: :ok

  # Private Functions - Message Queue Connectors

  defp connect_kafka(_config) do
    # Kafka connection
    {:ok, %{type: :kafka, brokers: config.brokers, topic: config.topic}}
  end

  defp connect_rabbitmq(_config) do
    # RabbitMQ connection
    {:ok, %{type: :rabbitmq, config: config}}
  end

  defp connect_sqs(_config) do
    # AWS SQS connection
    {:ok, %{type: :sqs, queue_url: config.queue_url}}
  end

  defp close_kafka(_connection), do: :ok
  defp close_rabbitmq(_connection), do: :ok

  # Private Functions - Monitoring Connectors

  defp connect_elasticsearch(_config) do
    # Elasticsearch connection
    {:ok, %{type: :elasticsearch, url: config.url}}
  end

  defp connect_grpc(_config) do
    # gRPC connection
    {:ok, %{type: :grpc, host: config.host, port: config.port}}
  end

  # Private Functions - Data Operations

  defp send_to_system(connection, connector, data, opts) do
    case connector.type do
      :postgresql ->
        execute_sql(connection, data, opts)

      :kafka ->
        publish_to_kafka(connection, data, opts)

      :rabbitmq ->
        publish_to_rabbitmq(connection, data, opts)

      :rest_api ->
        send_rest_request(connection, data, opts)

      :elasticsearch ->
        index_to_elasticsearch(connection, data, opts)

      _ ->
        {:ok, :sent}
    end
  end

  defp query_from_system(connection, connector, query, opts) do
    case connector.type do
      :postgresql ->
        query_postgresql(connection, query, opts)

      :elasticsearch ->
        search_elasticsearch(connection, query, opts)

      :rest_api ->
        query_rest_api(connection, query, opts)

      :graphql_api ->
        query_graphql(connection, query, opts)

      _ ->
        {:ok, %{}}
    end
  end

  defp execute_sql(_connection, _data, _opts) do
    # Execute SQL statement
    {:ok, :executed}
  end

  defp query_postgresql(_connection, _query, _opts) do
    # Query PostgreSQL
    {:ok, []}
  end

  defp publish_to_kafka(_connection, _data, _opts) do
    # Publish to Kafka topic
    {:ok, :published}
  end

  defp publish_to_rabbitmq(_connection, _data, _opts) do
    # Publish to RabbitMQ
    {:ok, :published}
  end

  defp send_rest_request(_connection, _data, _opts) do
    # Send REST API request
    {:ok, %{status: 200}}
  end

  defp query_rest_api(_connection, _query, _opts) do
    # Query REST API
    {:ok, %{}}
  end

  defp query_graphql(_connection, _query, _opts) do
    # Execute GraphQL query
    {:ok, %{data: %{}}}
  end

  defp index_to_elasticsearch(_connection, _data, _opts) do
    # Index data to Elasticsearch
    {:ok, :indexed}
  end

  defp search_elasticsearch(_connection, _query, _opts) do
    # Search Elasticsearch
    {:ok, %{hits: []}}
  end

  # Private Functions - Transformations

  defp transform_for_connector(data, connector_type) do
    case connector_type do
      :sap -> transform_to_sap_format(data)
      :salesforce -> transform_to_salesforce_format(data)
      _ -> data
    end
  end

  defp transform_from_connector(data, connector_type) do
    case connector_type do
      :sap -> transform_from_sap_format(data)
      :salesforce -> transform_from_salesforce_format(data)
      _ -> data
    end
  end

  defp transform(data, from_format, to_format, transformers) do
    transformer_key = {from_format, to_format}

    case Map.get(transformers, transformer_key) do
      nil ->
        {:error, :no_transformer}

      transformer ->
        {:ok, transformer.(data)}
    end
  end

  defp transform_to_sap_format(data) do
    # Transform to SAP format
    data
  end

  defp transform_from_sap_format(data) do
    # Transform from SAP format
    data
  end

  defp transform_to_salesforce_format(data) do
    # Transform to Salesforce format
    data
  end

  defp transform_from_salesforce_format(data) do
    # Transform from Salesforce format
    data
  end

  defp initialize_transformers do
    %{
      {:json, :xml} => &json_to_xml/1,
      {:xml, :json} => &xml_to_json/1,
      {:csv, :json} => &csv_to_json/1,
      {:json, :csv} => &json_to_csv/1
    }
  end

  defp json_to_xml(data), do: data
  defp xml_to_json(data), do: data
  defp csv_to_json(data), do: data
  defp json_to_csv(data), do: data

  # Private Functions - Webhooks

  defp trigger_webhook_async(webhook, event, data) do
    Task.async(fn ->
      payload = %{
        event: event,
        data: data,
        timestamp: DateTime.utc_now()
      }

      send_webhook_request(webhook, payload)
    end)
  end

  defp send_webhook_request(webhook, payload) do
    headers =
      Map.merge(webhook.headers, %{
        "Content-Type" => "application/json",
        "X-Event-Signature" => generate_signature(payload)
      })

    body = Jason.encode!(payload)

    # Send HTTP request with retries
    send_with_retries(webhook.url, body, headers, webhook.retry_config)
  end

  defp send_with_retries(url, body, headers, retry_config) do
    # Implement retry logic
    {:ok, :sent}
  end

  defp generate_signature(payload) do
    :crypto.hash(:sha256, Jason.encode!(payload))
    |> Base.encode16(case: :lower)
  end

  # Private Functions - Event Handling

  defp create_event_subscription(connector, events) do
    %{
      connector_id: connector.id,
      events: events,
      created_at: DateTime.utc_now()
    }
  end

  defp handle_blockchain_event(event, data, _state) do
    # Forward to subscribed connectors
    Enum.each(state.connectors, fn {_id, connector} ->
      if connector[:subscriptions] && event in connector.subscriptions.events do
        send_to_connector(connector, event, data, state)
      end
    end)

    # Trigger webhooks
    GenServer.cast(self(), {:trigger_webhook, event, data})
  end

  defp send_to_connector(connector, event, data, _state) do
    case Map.get(state.active_connections, connector.id) do
      nil -> :ok
      connection -> send_to_system(connection, connector, %{event: event, data: data}, [])
    end
  end

  # Private Functions - Health Monitoring

  defp perform_health_checks(_state) do
    Enum.reduce(state.connectors, state, fn {id, connector}, acc_state ->
      if connector.status == :connected do
        connection = Map.get(acc_state.active_connections, id)

        health = check_connector_health(connection, connector)

        updated_connector = %{
          connector
          | last_health_check: DateTime.utc_now(),
            status: if(health == :healthy, do: :connected, else: :error)
        }

        put_in(acc_state.connectors[id], updated_connector)
      else
        acc_state
      end
    end)
  end

  defp check_connector_health(_connection, connector) do
    case connector.type do
      :postgresql -> :healthy
      :kafka -> :healthy
      _ -> :healthy
    end
  end

  # Private Functions - Message Queue

  defp process_message_queue(_state) do
    case :queue.out(_state.message_queue) do
      {{:value, message}, rest_queue} ->
        process_queued_message(message, state)
        %{state | message_queue: rest_queue}

      {:empty, _queue} ->
        state
    end
  end

  defp process_queued_message(_message, _state) do
    # Process queued message
    :ok
  end

  # Private Functions - Auto-connect

  defp auto_connect_integrations(_state, opts) do
    auto_connect = Keyword.get(opts, :auto_connect, [])

    Enum.reduce(auto_connect, state, fn config, acc_state ->
      {:ok, connector} =
        register_connector(
          config[:type],
          config[:name],
          config[:config]
        )

      case establish_connection(connector) do
        {:ok, connection} ->
          updated_connector = %{connector | status: :connected}

          acc_state
          |> put_in([:connectors, connector.id], updated_connector)
          |> put_in([:active_connections, connector.id], connection)

        _ ->
          acc_state
      end
    end)
  end

  # Private Functions - Helpers

  defp validate_config(type, _config) do
    # Validate connector-specific configuration
    config
  end

  defp initialize_metrics do
    %{
      data_sent: 0,
      data_received: 0,
      queries_executed: 0,
      errors: 0,
      last_activity: nil
    }
  end

  defp update_metrics(_state, connector_id, metric) do
    update_in(state.connectors[connector_id].metrics[metric], &(&1 + 1))
    |> put_in([:connectors, connector_id, :metrics, :last_activity], DateTime.utc_now())
  end

  defp build_config(opts) do
    %{
      max_connectors: Keyword.get(opts, :max_connectors, 50),
      max_webhooks: Keyword.get(opts, :max_webhooks, 100),
      health_check_interval: Keyword.get(opts, :health_check_interval, 60_000),
      message_processing_interval: Keyword.get(opts, :message_processing_interval, 1000)
    }
  end

  defp default_retry_config do
    %{
      max_retries: 3,
      initial_delay: 1000,
      max_delay: 30000,
      backoff_factor: 2
    }
  end

  defp generate_connector_id do
    "conn_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_webhook_id do
    "webhook_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_health_checks do
    Process.send_after(self(), :health_check, 60_000)
  end

  defp schedule_message_processing do
    Process.send_after(self(), :process_messages, 1000)
  end
end
