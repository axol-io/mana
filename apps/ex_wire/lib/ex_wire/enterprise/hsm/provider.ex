defmodule ExWire.Enterprise.HSM.Provider do
  @moduledoc """
  Behavior definition for HSM providers.

  All HSM providers must implement this behavior to ensure
  consistent interface across different HSM backends.
  """

  @type connection :: any()
  @type key_type :: :ecdsa | :rsa | :ed25519 | :aes
  @type algorithm ::
          :ecdsa_sha256
          | :ecdsa_sha384
          | :ecdsa_sha512
          | :rsa_sha256
          | :rsa_sha384
          | :rsa_sha512
          | :rsa_pss_sha256
          | :raw

  @type key_info :: %{
          required(:key_id) => String.t(),
          required(:key_type) => key_type(),
          required(:created_at) => DateTime.t(),
          optional(any()) => any()
        }

  @type encrypted_data :: %{
          required(:ciphertext) => binary(),
          optional(any()) => any()
        }

  @doc """
  Establishes connection to the HSM.
  """
  @callback connect(config :: map()) :: {:ok, connection()} | {:error, term()}

  @doc """
  Disconnects from the HSM.
  """
  @callback disconnect(connection()) :: :ok | {:error, term()}

  @doc """
  Generates a new key in the HSM.
  """
  @callback generate_key(connection(), key_type(), key_id :: String.t(), opts :: keyword()) ::
              {:ok, key_info()} | {:error, term()}

  @doc """
  Signs data using an HSM-protected key.
  """
  @callback sign(connection(), key_id :: String.t(), data :: binary(), algorithm()) ::
              {:ok, signature :: binary()} | {:error, term()}

  @doc """
  Verifies a signature using an HSM-protected key.
  """
  @callback verify(
              connection(),
              key_id :: String.t(),
              data :: binary(),
              signature :: binary(),
              algorithm()
            ) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Encrypts data using an HSM-protected key.
  """
  @callback encrypt(connection(), key_id :: String.t(), plaintext :: binary()) ::
              {:ok, encrypted_data()} | {:error, term()}

  @doc """
  Decrypts data using an HSM-protected key.
  """
  @callback decrypt(connection(), key_id :: String.t(), encrypted_data()) ::
              {:ok, plaintext :: binary()} | {:error, term()}

  @doc """
  Lists all keys in the HSM.
  """
  @callback list_keys(connection()) :: {:ok, [key_info()]} | {:error, term()}

  @doc """
  Deletes a key from the HSM.
  """
  @callback delete_key(connection(), key_id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Performs health check on the HSM connection.
  """
  @callback health_check(connection()) :: {:ok, map()} | {:error, term()}

  @doc """
  Imports an existing key into the HSM (optional).
  """
  @callback import_key(
              connection(),
              key_data :: binary(),
              key_id :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, key_info()} | {:error, term()}

  @optional_callbacks [import_key: 4]
end
