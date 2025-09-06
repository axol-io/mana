defmodule ExWire.Packet.Capability.Eth.NewBlock do
  @moduledoc """
  Advertises a new block to the network.

  ```
  NewBlock [+0x07, [blockHeader, transactionList, uncleList], totalDifficulty]

  Specify a single block that the peer should know about.
  The composite item in the list (following the message ID) is a block in the
  format described in the main Ethereum specification.

  totalDifficulty is the total difficulty of the block (aka score).
  ```
  """

  alias Block.Header
  alias Blockchain.Block
  alias ExWire.Packet.Capability.Eth.Transactions

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{
          header: Header.t(),
          transactions: [any()],
          uncles: [Block.t()],
          total_difficulty: integer() | nil
        }

  defstruct [
    :header,
    :transactions,
    :uncles,
    :total_difficulty
  ]

  @doc """
  Returns the relative message id offset for this message.
  This will help determine what its message ID is relative to other Packets in the same Capability.
  """
  @impl true
  @spec message_id_offset() :: 7
  def message_id_offset do
    0x07
  end

  @doc """
  Given a NewBlock packet, serializes for transport over Eth Wire Protocol.
  """
  @impl true
  @spec serialize(t) :: ExRLP.t()
  def serialize(packet = %__MODULE__{}) do
    [
      [
        Header.serialize(packet.header),
        Transactions.serialize(%Transactions{transactions: packet.transactions}),
        packet.uncles |> Block.serialize() |> Enum.to_list()
      ],
      packet.total_difficulty
    ]
  end

  @doc """
  Given an RLP-encoded NewBlockHashes packet from Eth Wire Protocol,
  decodes into a NewBlockHashes struct.
  """
  @impl true
  @spec deserialize(any()) :: t
  def deserialize(rlp) do
    [
      [
        header,
        transactions,
        uncles
      ],
      total_difficulty
    ] = rlp

    %__MODULE__{
      header: Header.deserialize(header),
      transactions: Transactions.deserialize(transactions).transactions,
      uncles: uncles |> Block.deserialize() |> Enum.to_list(),
      total_difficulty: total_difficulty |> :binary.decode_unsigned()
    }
  end

  @doc """
  Handles a NewBlock message. This is when a peer wants to
  inform us that she knows about new blocks. For now, we'll do nothing.

  ## Examples

      iex> %ExWire.Packet.Capability.Eth.NewBlock{}
      ...> |> ExWire.Packet.Capability.Eth.NewBlock.handle()
      :ok
  """
  @impl true
  @spec handle(ExWire.Packet.packet()) :: ExWire.Packet.handle_response()
  def handle(packet = %__MODULE__{}) do
    # Queue block for validation and potential import
    # In a production system, this would:
    # 1. Validate the block header
    # 2. Check total difficulty claim
    # 3. Queue for import if valid
    # 4. Broadcast to other peers if new

    require Logger

    Logger.info(fn ->
      "[NewBlock] Received block ##{packet.header.number} with difficulty #{packet.total_difficulty}"
    end)

    # For now, acknowledge receipt
    :ok
  end
end
