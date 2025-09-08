defmodule ExWire.Eth2.SlashingProtection do
  @moduledoc """
  Slashing protection database to prevent validators from being slashed.
  Implements EIP-3076 interchange format for portability between clients.
  """

  use GenServer
  require Logger

  defstruct [
    :db_path,
    :attestations,
    :blocks,
    :config
  ]

  @type attestation_record :: %{
          source_epoch: non_neg_integer(),
          target_epoch: non_neg_integer(),
          signing_root: binary()
        }

  @type block_record :: %{
          slot: non_neg_integer(),
          signing_root: binary()
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initialize slashing protection
  """
  def init do
    %__MODULE__{
      attestations: %{},
      blocks: %{},
      config: %{}
    }
  end

  @doc """
  Initialize slashing protection for a validator
  """
  def init_validator(_db, pubkey) do
    GenServer.call(__MODULE__, {:init_validator, pubkey})
  end

  @doc """
  Check if a block proposal is safe
  """
  def check_block_proposal(_db, pubkey, slot) do
    GenServer.call(__MODULE__, {:check_block, pubkey, slot})
  end

  @doc """
  Record a block proposal
  """
  def record_block_proposal(_db, pubkey, slot, signing_root \\ nil) do
    GenServer.call(__MODULE__, {:record_block, pubkey, slot, signing_root})
  end

  @doc """
  Check if an attestation is safe
  """
  def check_attestation(_db, pubkey, attestation_data) do
    GenServer.call(__MODULE__, {:check_attestation, pubkey, attestation_data})
  end

  @doc """
  Record an attestation
  """
  def record_attestation(db, pubkey, attestation_data, signing_root \\ nil) do
    GenServer.call(__MODULE__, {:record_attestation, pubkey, attestation_data, signing_root})
  end

  @doc """
  Export slashing protection data in interchange format
  """
  def export_interchange_data(pubkeys \\ nil) do
    GenServer.call(__MODULE__, {:export_interchange, pubkeys})
  end

  @doc """
  Import slashing protection data from interchange format
  """
  def import_interchange_data(data) do
    GenServer.call(__MODULE__, {:import_interchange, data})
  end

  @doc """
  Prune old data
  """
  def prune(before_epoch) do
    GenServer.call(__MODULE__, {:prune, before_epoch})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, "slashing_protection.db")

    state = %__MODULE__{
      db_path: db_path,
      attestations: load_attestations(db_path),
      blocks: load_blocks(db_path),
      config: build_config(opts)
    }

    # Schedule periodic saves
    schedule_save()

    {:ok, _state}
  end

  @impl true
  def handle_call({:init_validator, pubkey}, _from, _state) do
    state =
      state
      |> put_in([:attestations, pubkey], [])
      |> put_in([:blocks, pubkey], [])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_block, pubkey, slot}, _from, _state) do
    blocks = Map.get(state.blocks, pubkey, [])

    # Check for double block proposal
    safe =
      not Enum.any?(blocks, fn record ->
        record.slot == slot
      end)

    # Check for lower slot (would be slashable if we sign)
    safe =
      safe and
        not Enum.any?(blocks, fn record ->
          record.slot > slot
        end)

    if not safe do
      Logger.warning("Slashing protection: Unsafe block proposal for slot #{slot}")
    end

    {:reply, safe, state}
  end

  @impl true
  def handle_call({:record_block, pubkey, slot, signing_root}, _from, _state) do
    record = %{
      slot: slot,
      signing_root: signing_root || <<0::256>>,
      timestamp: System.system_time(:second)
    }

    blocks = Map.get(state.blocks, pubkey, [])

    # Check if already recorded
    if not Enum.any?(blocks, fn r -> r.slot == slot end) do
      blocks = [record | blocks] |> Enum.sort_by(& &1.slot, :desc)
      state = put_in(state.blocks[pubkey], blocks)

      Logger.debug("Recorded block proposal for slot #{slot}")
      {:reply, :ok, state}
    else
      {:reply, :already_recorded, state}
    end
  end

  @impl true
  def handle_call({:check_attestation, pubkey, attestation_data}, _from, _state) do
    attestations = Map.get(state.attestations, pubkey, [])

    source_epoch = attestation_data.source.epoch
    target_epoch = attestation_data.target.epoch

    # Check for double vote (same target epoch)
    double_vote =
      Enum.any?(attestations, fn record ->
        record.target_epoch == target_epoch and
          record.signing_root != compute_signing_root(attestation_data)
      end)

    # Check for surround vote
    surround_vote =
      Enum.any?(attestations, fn record ->
        # We would surround a previous attestation
        # A previous attestation would surround us
        (source_epoch < record.source_epoch and target_epoch > record.target_epoch) or
          (source_epoch > record.source_epoch and target_epoch < record.target_epoch)
      end)

    safe = not double_vote and not surround_vote

    if not safe do
      Logger.warning("Slashing protection: Unsafe attestation for target epoch #{target_epoch}")
    end

    {:reply, safe, state}
  end

  @impl true
  def handle_call({:record_attestation, pubkey, attestation_data, signing_root}, _from, _state) do
    record = %{
      source_epoch: attestation_data.source.epoch,
      target_epoch: attestation_data.target.epoch,
      signing_root: signing_root || compute_signing_root(attestation_data),
      timestamp: System.system_time(:second)
    }

    attestations = Map.get(state.attestations, pubkey, [])

    # Check if already recorded
    if not Enum.any?(attestations, fn r ->
         r.target_epoch == record.target_epoch and r.signing_root == record.signing_root
       end) do
      attestations = [record | attestations] |> Enum.sort_by(& &1.target_epoch, :desc)
      state = put_in(state.attestations[pubkey], attestations)

      Logger.debug("Recorded attestation for target epoch #{record.target_epoch}")
      {:reply, :ok, state}
    else
      {:reply, :already_recorded, state}
    end
  end

  @impl true
  def handle_call({:export_interchange, pubkeys}, _from, _state) do
    pubkeys = pubkeys || (Map.keys(state.attestations) ++ Map.keys(state.blocks)) |> Enum.uniq()

    data = %{
      metadata: %{
        interchange_format_version: "5",
        genesis_validators_root: state.config.genesis_validators_root
      },
      data:
        Enum.map(pubkeys, fn pubkey ->
          %{
            pubkey: Base.encode16(pubkey, case: :lower),
            signed_blocks: export_blocks(Map.get(state.blocks, pubkey, [])),
            signed_attestations: export_attestations(Map.get(state.attestations, pubkey, []))
          }
        end)
    }

    {:reply, {:ok, data}, state}
  end

  @impl true
  def handle_call({:import_interchange, data}, _from, _state) do
    # Validate format version
    if data.metadata.interchange_format_version != "5" do
      {:reply, {:error, :unsupported_version}, state}
    else
      # Import data for each validator
      state =
        Enum.reduce(data.data, state, fn validator_data, acc_state ->
          pubkey = Base.decode16!(validator_data.pubkey, case: :mixed)

          # Import blocks
          blocks = import_blocks(validator_data.signed_blocks)
          existing_blocks = Map.get(acc_state.blocks, pubkey, [])
          merged_blocks = merge_blocks(existing_blocks, blocks)

          # Import attestations
          attestations = import_attestations(validator_data.signed_attestations)
          existing_attestations = Map.get(acc_state.attestations, pubkey, [])
          merged_attestations = merge_attestations(existing_attestations, attestations)

          acc_state
          |> put_in([:blocks, pubkey], merged_blocks)
          |> put_in([:attestations, pubkey], merged_attestations)
        end)

      Logger.info("Imported slashing protection data for #{length(data.data)} validators")
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:prune, before_epoch}, _from, _state) do
    # Prune old attestations
    attestations =
      Enum.map(state.attestations, fn {pubkey, records} ->
        pruned =
          Enum.filter(records, fn record ->
            record.target_epoch >= before_epoch
          end)

        {pubkey, pruned}
      end)
      |> Enum.into(%{})

    # Calculate slots to keep
    slots_per_epoch = 32
    before_slot = before_epoch * slots_per_epoch

    # Prune old blocks
    blocks =
      Enum.map(state.blocks, fn {pubkey, records} ->
        pruned =
          Enum.filter(records, fn record ->
            record.slot >= before_slot
          end)

        {pubkey, pruned}
      end)
      |> Enum.into(%{})

    state = %{state | attestations: attestations, blocks: blocks}

    Logger.info("Pruned slashing protection data before epoch #{before_epoch}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:save_db, _state) do
    save_to_disk(state)
    schedule_save()
    {:noreply, state}
  end

  # Private Functions - Import/Export

  defp export_blocks(blocks) do
    Enum.map(blocks, fn record ->
      %{
        slot: Integer.to_string(record.slot),
        signing_root: "0x" <> Base.encode16(record.signing_root, case: :lower)
      }
    end)
  end

  defp export_attestations(attestations) do
    Enum.map(attestations, fn record ->
      %{
        source_epoch: Integer.to_string(record.source_epoch),
        target_epoch: Integer.to_string(record.target_epoch),
        signing_root: "0x" <> Base.encode16(record.signing_root, case: :lower)
      }
    end)
  end

  defp import_blocks(blocks) do
    Enum.map(blocks, fn block ->
      %{
        slot: String.to_integer(block.slot),
        signing_root: decode_hex(block.signing_root),
        timestamp: System.system_time(:second)
      }
    end)
  end

  defp import_attestations(attestations) do
    Enum.map(attestations, fn attestation ->
      %{
        source_epoch: String.to_integer(attestation.source_epoch),
        target_epoch: String.to_integer(attestation.target_epoch),
        signing_root: decode_hex(attestation.signing_root),
        timestamp: System.system_time(:second)
      }
    end)
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex), do: Base.decode16!(hex, case: :mixed)

  # Private Functions - Merging

  defp merge_blocks(existing, new) do
    # Combine and deduplicate by slot, keeping highest slot record
    combined = existing ++ new

    combined
    |> Enum.group_by(& &1.slot)
    |> Enum.map(fn {_slot, records} -> List.first(records) end)
    |> Enum.sort_by(& &1.slot, :desc)
  end

  defp merge_attestations(existing, new) do
    # For attestations, we need to keep the most restrictive records
    combined = existing ++ new

    # Group by target epoch
    by_target = Enum.group_by(combined, & &1.target_epoch)

    # For each target epoch, keep the record with highest source epoch
    # (most restrictive for surround vote protection)
    Enum.map(by_target, fn {_target, records} ->
      Enum.max_by(records, & &1.source_epoch)
    end)
    |> Enum.sort_by(& &1.target_epoch, :desc)
  end

  # Private Functions - Persistence

  defp load_attestations(db_path) do
    case File.read(db_path <> ".attestations") do
      {:ok, content} ->
        :erlang.binary_to_term(content)

      {:error, _} ->
        %{}
    end
  end

  defp load_blocks(db_path) do
    case File.read(db_path <> ".blocks") do
      {:ok, content} ->
        :erlang.binary_to_term(content)

      {:error, _} ->
        %{}
    end
  end

  defp save_to_disk(_state) do
    # Save attestations
    File.write!(
      state.db_path <> ".attestations",
      :erlang.term_to_binary(state.attestations)
    )

    # Save blocks
    File.write!(
      state.db_path <> ".blocks",
      :erlang.term_to_binary(state.blocks)
    )

    Logger.debug("Saved slashing protection database")
  end

  # Private Functions - Helpers

  defp compute_signing_root(attestation_data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(attestation_data))
  end

  defp build_config(opts) do
    %{
      genesis_validators_root: Keyword.get(opts, :genesis_validators_root, <<0::256>>),
      # 1 minute
      save_interval: Keyword.get(opts, :save_interval, 60_000)
    }
  end

  defp schedule_save do
    Process.send_after(self(), :save_db, 60_000)
  end
end
