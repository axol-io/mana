defmodule ExWire.Enterprise.MultisigWallet do
  @moduledoc """
  Enterprise-grade multi-signature wallet implementation for institutional adoption.
  Supports threshold signatures, time-locked transactions, and multi-party approval workflows.
  """

  use GenServer
  require Logger

  alias ExWire.Transaction
  alias ExWire.Enterprise.AuditLogger

  defstruct [
    :wallet_id,
    :name,
    :owners,
    :required_signatures,
    :pending_transactions,
    :executed_transactions,
    :daily_limit,
    :daily_spent,
    :policies,
    :created_at,
    :metadata
  ]

  @type owner :: %{
          address: binary(),
          name: String.t(),
          public_key: binary(),
          permissions: list(atom()),
          added_at: DateTime.t()
        }

  @type pending_tx :: %{
          tx_id: String.t(),
          transaction: Transaction.t(),
          approvals: list(binary()),
          rejections: list(binary()),
          created_by: binary(),
          created_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  @type policy :: %{
          type: :daily_limit | :whitelist | :time_lock | :value_threshold,
          value: any(),
          enabled: boolean()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Create a new multi-signature wallet
  """
  def create_wallet(name, owners, required_signatures, opts \\ []) do
    GenServer.call(__MODULE__, {:create_wallet, name, owners, required_signatures, opts})
  end

  @doc """
  Add a new owner to the wallet
  """
  def add_owner(wallet_id, new_owner, approver) do
    GenServer.call(__MODULE__, {:add_owner, wallet_id, new_owner, approver})
  end

  @doc """
  Remove an owner from the wallet
  """
  def remove_owner(wallet_id, owner_address, approver) do
    GenServer.call(__MODULE__, {:remove_owner, wallet_id, owner_address, approver})
  end

  @doc """
  Submit a transaction for approval
  """
  def submit_transaction(wallet_id, transaction, submitter) do
    GenServer.call(__MODULE__, {:submit_transaction, wallet_id, transaction, submitter})
  end

  @doc """
  Approve a pending transaction
  """
  def approve_transaction(wallet_id, tx_id, approver) do
    GenServer.call(__MODULE__, {:approve_transaction, wallet_id, tx_id, approver})
  end

  @doc """
  Reject a pending transaction
  """
  def reject_transaction(wallet_id, tx_id, rejector) do
    GenServer.call(__MODULE__, {:reject_transaction, wallet_id, tx_id, rejector})
  end

  @doc """
  Execute an approved transaction
  """
  def execute_transaction(wallet_id, tx_id) do
    GenServer.call(__MODULE__, {:execute_transaction, wallet_id, tx_id})
  end

  @doc """
  Get wallet information
  """
  def get_wallet(wallet_id) do
    GenServer.call(__MODULE__, {:get_wallet, wallet_id})
  end

  @doc """
  List pending transactions
  """
  def list_pending_transactions(wallet_id) do
    GenServer.call(__MODULE__, {:list_pending_transactions, wallet_id})
  end

  @doc """
  Update wallet policies
  """
  def update_policy(wallet_id, policy_type, value, approver) do
    GenServer.call(__MODULE__, {:update_policy, wallet_id, policy_type, value, approver})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting MultisigWallet manager")

    state = %{
      wallets: %{},
      wallet_by_address: %{},
      config: Keyword.get(opts, :config, default_config())
    }

    schedule_cleanup()
    {:ok, _state}
  end

  @impl true
  def handle_call({:create_wallet, name, owners, required_signatures, opts}, _from, _state) do
    wallet_id = generate_wallet_id()

    wallet = %__MODULE__{
      wallet_id: wallet_id,
      name: name,
      owners: validate_owners(owners),
      required_signatures: required_signatures,
      pending_transactions: %{},
      executed_transactions: [],
      daily_limit: Keyword.get(opts, :daily_limit, 0),
      daily_spent: 0,
      policies: initialize_policies(opts),
      created_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # Validate configuration
    if required_signatures > length(owners) do
      {:reply, {:error, :invalid_threshold}, state}
    else
      state = put_in(state.wallets[wallet_id], wallet)

      # Log wallet creation
      AuditLogger.log(:wallet_created, %{
        wallet_id: wallet_id,
        name: name,
        owners: length(owners),
        threshold: required_signatures
      })

      {:reply, {:ok, wallet}, state}
    end
  end

  @impl true
  def handle_call({:add_owner, wallet_id, new_owner, approver}, _from, _state) do
    case Map.get(state.wallets, wallet_id) do
      nil ->
        {:reply, {:error, :wallet_not_found}, state}

      wallet ->
        if is_owner?(wallet, approver) do
          updated_wallet = update_in(wallet.owners, &[validate_owner(new_owner) | &1])
          state = put_in(state.wallets[wallet_id], updated_wallet)

          AuditLogger.log(:owner_added, %{
            wallet_id: wallet_id,
            new_owner: new_owner.address,
            approver: approver
          })

          {:reply, {:ok, updated_wallet}, state}
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:submit_transaction, wallet_id, transaction, submitter}, _from, _state) do
    case Map.get(state.wallets, wallet_id) do
      nil ->
        {:reply, {:error, :wallet_not_found}, state}

      wallet ->
        if is_owner?(wallet, submitter) do
          tx_id = generate_tx_id()

          pending_tx = %{
            tx_id: tx_id,
            transaction: transaction,
            approvals: [submitter],
            rejections: [],
            created_by: submitter,
            created_at: DateTime.utc_now(),
            expires_at: calculate_expiry(wallet),
            metadata: %{}
          }

          # Check policies
          case check_policies(wallet, transaction) do
            :ok ->
              updated_wallet = put_in(wallet.pending_transactions[tx_id], pending_tx)
              state = put_in(_state.wallets[wallet_id], updated_wallet)

              AuditLogger.log(:transaction_submitted, %{
                wallet_id: wallet_id,
                tx_id: tx_id,
                submitter: submitter,
                value: transaction.value
              })

              # Check if auto-executable
              state = maybe_auto_execute(state, wallet_id, tx_id)

              {:reply, {:ok, tx_id}, state}

            {:error, _reason} ->
              {:reply, {:error, _reason}, state}
          end
        else
          {:reply, {:error, :unauthorized}, state}
        end
    end
  end

  @impl true
  def handle_call({:approve_transaction, wallet_id, tx_id, approver}, _from, _state) do
    case get_in(state, [:wallets, wallet_id]) do
      nil ->
        {:reply, {:error, :wallet_not_found}, state}

      wallet ->
        case Map.get(wallet.pending_transactions, tx_id) do
          nil ->
            {:reply, {:error, :transaction_not_found}, state}

          pending_tx ->
            if is_owner?(wallet, approver) && approver not in pending_tx.approvals do
              updated_tx = update_in(pending_tx.approvals, &[approver | &1])
              updated_wallet = put_in(wallet.pending_transactions[tx_id], updated_tx)
              state = put_in(state.wallets[wallet_id], updated_wallet)

              AuditLogger.log(:transaction_approved, %{
                wallet_id: wallet_id,
                tx_id: tx_id,
                approver: approver,
                approvals: length(updated_tx.approvals),
                required: wallet.required_signatures
              })

              # Check if ready to execute
              state = maybe_auto_execute(state, wallet_id, tx_id)

              {:reply, {:ok, updated_tx}, state}
            else
              {:reply, {:error, :unauthorized_or_duplicate}, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:execute_transaction, wallet_id, tx_id}, _from, _state) do
    case get_in(state, [:wallets, wallet_id]) do
      nil ->
        {:reply, {:error, :wallet_not_found}, state}

      wallet ->
        case Map.get(wallet.pending_transactions, tx_id) do
          nil ->
            {:reply, {:error, :transaction_not_found}, state}

          pending_tx ->
            if length(pending_tx.approvals) >= wallet.required_signatures do
              # Execute the transaction
              case execute_blockchain_transaction(pending_tx.transaction) do
                {:ok, tx_hash} ->
                  # Move to executed
                  executed_tx = Map.put(pending_tx, :executed_at, DateTime.utc_now())
                  executed_tx = Map.put(executed_tx, :tx_hash, tx_hash)

                  updated_wallet =
                    wallet
                    |> update_in([Access.key(:pending_transactions)], &Map.delete(&1, tx_id))
                    |> update_in([Access.key(:executed_transactions)], &[executed_tx | &1])
                    |> update_daily_spent(pending_tx.transaction.value)

                  state = put_in(state.wallets[wallet_id], updated_wallet)

                  AuditLogger.log(:transaction_executed, %{
                    wallet_id: wallet_id,
                    tx_id: tx_id,
                    tx_hash: tx_hash,
                    value: pending_tx.transaction.value
                  })

                  {:reply, {:ok, tx_hash}, state}

                {:error, _reason} ->
                  {:reply, {:error, _reason}, state}
              end
            else
              {:reply, {:error, :insufficient_approvals}, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:get_wallet, wallet_id}, _from, _state) do
    case Map.get(state.wallets, wallet_id) do
      nil -> {:reply, {:error, :wallet_not_found}, state}
      wallet -> {:reply, {:ok, sanitize_wallet(wallet)}, state}
    end
  end

  @impl true
  def handle_call({:list_pending_transactions, wallet_id}, _from, _state) do
    case Map.get(state.wallets, wallet_id) do
      nil ->
        {:reply, {:error, :wallet_not_found}, state}

      wallet ->
        pending = Map.values(wallet.pending_transactions)
        {:reply, {:ok, pending}, state}
    end
  end

  @impl true
  def handle_info(:cleanup_expired, _state) do
    state = cleanup_expired_transactions(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions

  defp validate_owners(owners) do
    Enum.map(owners, &validate_owner/1)
  end

  defp validate_owner(owner) when is_map(owner) do
    %{
      address: owner.address,
      name: Map.get(owner, :name, "Unknown"),
      public_key: Map.get(owner, :public_key, nil),
      permissions: Map.get(owner, :permissions, [:sign, :submit, :approve]),
      added_at: DateTime.utc_now()
    }
  end

  defp is_owner?(wallet, address) do
    Enum.any?(wallet.owners, fn owner -> owner.address == address end)
  end

  defp initialize_policies(opts) do
    %{
      daily_limit: %{
        type: :daily_limit,
        value: Keyword.get(opts, :daily_limit, 0),
        enabled: Keyword.get(opts, :daily_limit, 0) > 0
      },
      whitelist: %{
        type: :whitelist,
        value: Keyword.get(opts, :whitelist, []),
        enabled: Keyword.has_key?(opts, :whitelist)
      },
      time_lock: %{
        type: :time_lock,
        value: Keyword.get(opts, :time_lock_hours, 0),
        enabled: Keyword.get(opts, :time_lock_hours, 0) > 0
      },
      value_threshold: %{
        type: :value_threshold,
        value: Keyword.get(opts, :value_threshold, 0),
        enabled: Keyword.get(opts, :value_threshold, 0) > 0
      }
    }
  end

  defp check_policies(wallet, transaction) do
    cond do
      # Check daily limit
      wallet.policies.daily_limit.enabled and
          wallet.daily_spent + transaction.value > wallet.policies.daily_limit.value ->
        {:error, :daily_limit_exceeded}

      # Check whitelist  
      wallet.policies.whitelist.enabled and
          transaction.to not in wallet.policies.whitelist.value ->
        {:error, :recipient_not_whitelisted}

      # Check value threshold
      wallet.policies.value_threshold.enabled and
          transaction.value > wallet.policies.value_threshold.value ->
        {:error, :value_exceeds_threshold}

      true ->
        :ok
    end
  end

  defp maybe_auto_execute(_state, wallet_id, tx_id) do
    wallet = state.wallets[wallet_id]
    pending_tx = wallet.pending_transactions[tx_id]

    if pending_tx && length(pending_tx.approvals) >= wallet.required_signatures do
      # Auto-execute if threshold reached
      {:ok, _tx_hash} = execute_blockchain_transaction(pending_tx.transaction)

      executed_tx = Map.put(pending_tx, :executed_at, DateTime.utc_now())

      updated_wallet =
        wallet
        |> update_in([Access.key(:pending_transactions)], &Map.delete(&1, tx_id))
        |> update_in([Access.key(:executed_transactions)], &[executed_tx | &1])
        |> update_daily_spent(pending_tx.transaction.value)

      put_in(state.wallets[wallet_id], updated_wallet)
    else
      state
    end
  end

  defp execute_blockchain_transaction(transaction) do
    # Integration with blockchain
    # This would normally submit to the transaction pool
    tx_hash = :crypto.hash(:sha256, :erlang.term_to_binary(transaction))
    {:ok, Base.encode16(tx_hash, case: :lower)}
  end

  defp update_daily_spent(wallet, amount) do
    # Reset daily spent if new day
    if Date.diff(Date.utc_today(), DateTime.to_date(wallet.created_at)) > 0 do
      %{wallet | daily_spent: amount}
    else
      update_in(wallet.daily_spent, &(&1 + amount))
    end
  end

  defp calculate_expiry(wallet) do
    if wallet.policies.time_lock.enabled do
      DateTime.add(DateTime.utc_now(), wallet.policies.time_lock.value * 3600, :second)
    else
      nil
    end
  end

  defp cleanup_expired_transactions(_state) do
    now = DateTime.utc_now()

    updated_wallets =
      Enum.map(state.wallets, fn {wallet_id, wallet} ->
        pending =
          Enum.filter(wallet.pending_transactions, fn {_tx_id, tx} ->
            tx.expires_at == nil || DateTime.compare(tx.expires_at, now) == :gt
          end)
          |> Enum.into(%{})

        {wallet_id, %{wallet | pending_transactions: pending}}
      end)
      |> Enum.into(%{})

    %{state | wallets: updated_wallets}
  end

  defp sanitize_wallet(wallet) do
    %{
      wallet_id: wallet.wallet_id,
      name: wallet.name,
      owners: Enum.map(wallet.owners, &sanitize_owner/1),
      required_signatures: wallet.required_signatures,
      pending_count: map_size(wallet.pending_transactions),
      executed_count: length(wallet.executed_transactions),
      daily_limit: wallet.daily_limit,
      daily_spent: wallet.daily_spent,
      created_at: wallet.created_at
    }
  end

  defp sanitize_owner(owner) do
    %{
      address: owner.address,
      name: owner.name,
      permissions: owner.permissions
    }
  end

  defp generate_wallet_id do
    "wallet_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp generate_tx_id do
    "tx_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, :timer.hours(1))
  end

  defp default_config do
    %{
      max_wallets: 1000,
      max_pending_per_wallet: 100,
      cleanup_interval: :timer.hours(1)
    }
  end
end
