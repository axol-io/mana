defmodule ExWire.Packet.Capability.Verkle do
  @moduledoc """
  Verkle tree protocol packets for efficient state synchronization.

  This module defines the network protocol packets specifically designed for
  Verkle tree operations, enabling efficient witness-based state synchronization
  and healing. The protocol is optimized for the compact nature of Verkle witnesses.

  Protocol packets:
  - GetWitnesses: Request witnesses for specific keys
  - Witnesses: Response containing Verkle witnesses
  - GetStateRange: Request state data for a range of keys
  - StateRange: Response containing state data with witnesses
  - GetHealingWitnesses: Request witnesses for state healing
  - HealingWitnesses: Response containing healing witnesses
  """

  @protocol_name "verkle"
  @protocol_version 1

  # Packet type IDs
  @get_witnesses_packet_id 0x01
  @witnesses_packet_id 0x02
  @get_state_range_packet_id 0x03
  @state_range_packet_id 0x04
  @get_healing_witnesses_packet_id 0x05
  @healing_witnesses_packet_id 0x06
  @verkle_status_packet_id 0x07
  @witness_verification_packet_id 0x08

  def protocol_name, do: @protocol_name
  def protocol_version, do: @protocol_version

  def packet_id_map do
    %{
      :get_witnesses => @get_witnesses_packet_id,
      :witnesses => @witnesses_packet_id,
      :get_state_range => @get_state_range_packet_id,
      :state_range => @state_range_packet_id,
      :get_healing_witnesses => @get_healing_witnesses_packet_id,
      :healing_witnesses => @healing_witnesses_packet_id,
      :verkle_status => @verkle_status_packet_id,
      :witness_verification => @witness_verification_packet_id
    }
  end

  def packet_type_from_id(packet_id) do
    case packet_id do
      @get_witnesses_packet_id -> :get_witnesses
      @witnesses_packet_id -> :witnesses
      @get_state_range_packet_id -> :get_state_range
      @state_range_packet_id -> :state_range
      @get_healing_witnesses_packet_id -> :get_healing_witnesses
      @healing_witnesses_packet_id -> :healing_witnesses
      @verkle_status_packet_id -> :verkle_status
      @witness_verification_packet_id -> :witness_verification
      _ -> :unknown
    end
  end
end
