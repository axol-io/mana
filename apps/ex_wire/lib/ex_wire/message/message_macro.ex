defmodule ExWire.Message.MessageMacro do
  @moduledoc """
  Macro for generating ExWire message modules with common behavior.
  Eliminates boilerplate code for message encoding/decoding.
  """

  defmacro __using__(opts) do
    message_id = Keyword.fetch!(opts, :message_id)
    fields = Keyword.fetch!(opts, :fields)

    quote do
      @behaviour ExWire.Message
      @message_id unquote(message_id)

      defstruct unquote(fields |> Keyword.keys())

      # Type spec will be generated differently
      @type t :: %__MODULE__{}

      @spec message_id() :: ExWire.Message.message_id()
      def message_id, do: @message_id

      @spec decode(binary()) :: t
      def decode(data) do
        decoded_values = ExRLP.decode(data)

        if length(decoded_values) != unquote(length(fields)) do
          raise MatchError, term: decoded_values
        end

        field_values =
          decoded_values
          |> Enum.zip(unquote(Keyword.keys(fields)))
          |> Enum.map(&decode_field/1)
          |> Enum.into(%{})

        struct(__MODULE__, field_values)
      end

      @spec encode(t) :: binary()
      def encode(%__MODULE__{} = msg) do
        values =
          unquote(Keyword.keys(fields))
          |> Enum.map(fn field ->
            Map.get(msg, field) |> encode_field(field)
          end)

        ExRLP.encode(values)
      end

      # Default implementations - can be overridden
      defp decode_field({value, field}) when field in [:version, :timestamp] do
        {field, :binary.decode_unsigned(value)}
      end

      defp decode_field({value, field}) when field in [:from, :to] do
        {field, ExWire.Struct.Endpoint.decode(value)}
      end

      defp decode_field({value, field}) do
        {field, value}
      end

      defp encode_field(%ExWire.Struct.Endpoint{} = endpoint, _field) do
        ExWire.Struct.Endpoint.encode(endpoint)
      end

      defp encode_field(value, _field) when is_integer(value) or is_binary(value) do
        value
      end

      defp encode_field(value, _field), do: value

      defoverridable decode_field: 1, encode_field: 2
    end
  end
end
