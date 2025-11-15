defmodule Blockchain.PropertyTesting.Generators do
  @moduledoc """
  Property testing generators for blockchain operations.

  This module provides StreamData generators for various blockchain
  data structures used in property-based tests.
  """

  use ExUnitProperties
  import StreamData

  @doc """
  Generates random transaction data.
  """
  def transaction_data do
    fixed_map(%{
      nonce: non_negative_integer(),
      gas_price: non_negative_integer(),
      gas_limit: positive_integer(),
      to: binary(length: 20),
      value: non_negative_integer(),
      data: binary()
    })
  end

  @doc """
  Generates random block headers.
  """
  def block_header do
    fixed_map(%{
      parent_hash: binary(length: 32),
      ommers_hash: binary(length: 32),
      beneficiary: binary(length: 20),
      state_root: binary(length: 32),
      transactions_root: binary(length: 32),
      receipts_root: binary(length: 32),
      logs_bloom: binary(length: 256),
      difficulty: positive_integer(),
      number: non_negative_integer(),
      gas_limit: positive_integer(),
      gas_used: non_negative_integer(),
      timestamp: positive_integer(),
      extra_data: binary(max_length: 32),
      mix_hash: binary(length: 32),
      nonce: binary(length: 8)
    })
  end

  @doc """
  Generates random addresses (20 bytes).
  """
  def address do
    binary(length: 20)
  end

  @doc """
  Generates random hash values (32 bytes).
  """
  def hash do
    binary(length: 32)
  end

  @doc """
  Generates random private keys (32 bytes).
  """
  def private_key do
    binary(length: 32)
  end

  @doc """
  Generates valid EVM bytecode.
  """
  def evm_bytecode do
    list_of(
      one_of([
        # PUSH operations
        # PUSH1
        constant(0x60),
        # PUSH2
        constant(0x61),
        # PUSH4
        constant(0x63),

        # Stack operations
        # DUP1
        constant(0x80),
        # SWAP1
        constant(0x90),
        # POP
        constant(0x50),

        # Arithmetic
        # ADD
        constant(0x01),
        # MUL
        constant(0x02),
        # SUB
        constant(0x03),

        # Storage
        # SLOAD
        constant(0x54),
        # SSTORE
        constant(0x55),

        # Control flow
        # STOP
        constant(0x00),
        # RETURN
        constant(0xF3)
      ])
    )
    |> map(&:binary.list_to_bin/1)
  end

  @doc """
  Generates Ethereum addresses (20 bytes).
  """
  def ethereum_address do
    binary(length: 20)
  end

  @doc """
  Generates Wei amounts (positive integers representing Wei).
  """
  def wei_amount do
    frequency([
      # Small amounts (0-1000 wei)
      {2, integer(0..1000)},
      # Medium amounts (1 finney to 100 finney)
      {2, integer(1_000_000_000_000_000..100_000_000_000_000_000)},
      # Large amounts (up to 1000 ether)
      {1, integer(1_000_000_000_000_000_000..1_000_000_000_000_000_000_000)}
    ])
  end

  @doc """
  Generates random transactions with valid structure.
  """
  def transaction do
    fixed_map(%{
      nonce: non_negative_integer(),
      gas_price: positive_integer(),
      gas_limit: integer(21_000..10_000_000),
      to: one_of([binary(length: 20), constant(<<>>)]),
      value: non_negative_integer(),
      data: binary(max_length: 1000),
      init: binary(max_length: 1000),
      v: integer(0..255),
      r: integer(0..0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF),
      s: integer(0..0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
    })
  end

  @doc """
  Generates random blocks with valid structure.
  """
  def block do
    fixed_map(%{
      hash: binary(length: 32),
      parent_hash: binary(length: 32),
      ommers_hash: binary(length: 32),
      beneficiary: binary(length: 20),
      state_root: binary(length: 32),
      transactions_root: binary(length: 32),
      receipts_root: binary(length: 32),
      logs_bloom: binary(length: 256),
      difficulty: positive_integer(),
      number: non_negative_integer(),
      gas_limit: integer(1_000_000..30_000_000),
      gas_used: non_negative_integer(),
      timestamp: positive_integer(),
      extra_data: binary(max_length: 32),
      mix_hash: binary(length: 32),
      nonce: binary(length: 8),
      transactions: list_of(transaction(), max_length: 100)
    })
  end
end
