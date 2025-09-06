defmodule ExWire.Enterprise.PKCS11NIF do
  @moduledoc """
  PKCS#11 Native Interface Functions for hardware HSM integration.

  This module provides a low-level interface to PKCS#11 hardware security modules.
  It handles session management, key generation, signing, and other cryptographic operations.
  """

  if System.get_env("RUSTLER_SKIP_COMPILE") != "1" do
    use Rustler, otp_app: :ex_wire, crate: "pkcs11_nif"
  end

  # NIF placeholders - these will be replaced by the Rust implementation

  @doc """
  Initialize PKCS#11 library with the specified library path.
  """
  def initialize_library(_library_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Finalize PKCS#11 library and clean up resources.
  """
  def finalize_library(_context_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Get available slots from the PKCS#11 device.
  """
  def get_slots(_context_id, _with_token), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Open a session to a PKCS#11 slot.
  """
  def open_session(_context_id, _slot_id, _read_write), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Close a PKCS#11 session.
  """
  def close_session(_context_id, _session_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Login to a PKCS#11 token.
  """
  def login(_context_id, _session_id, _user_type, _pin), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Logout from a PKCS#11 token.
  """
  def logout(_context_id, _session_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generate a key pair in the PKCS#11 device.
  """
  def generate_key_pair(_context_id, _session_id, _key_type, _key_size, _key_label, _extractable),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Sign data using a PKCS#11 private key.
  """
  def sign_data(_context_id, _session_id, _private_key_handle, _mechanism_type, _data),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Verify signature using a PKCS#11 public key.
  """
  def verify_signature(
        _context_id,
        _session_id,
        _public_key_handle,
        _mechanism_type,
        _data,
        _signature
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Find objects in the PKCS#11 device based on template attributes.
  """
  def find_objects(_context_id, _session_id, _template_attrs),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Destroy an object in the PKCS#11 device.
  """
  def destroy_object(_context_id, _session_id, _object_handle),
    do: :erlang.nif_error(:nif_not_loaded)

  # High-level convenience functions

  @doc """
  Initialize PKCS#11 with a library path and return context.
  """
  @spec init_pkcs11(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def init_pkcs11(library_path) do
    case initialize_library(library_path) do
      {:ok, context_id} -> {:ok, context_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Open session and login with PIN.
  """
  @spec open_session_and_login(String.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def open_session_and_login(context_id, slot_id, user_type \\ "user", pin) do
    with {:ok, session_id} <- open_session(context_id, slot_id, true),
         {:ok} <- login(context_id, session_id, user_type, pin) do
      {:ok, session_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generate ECDSA key pair with specified label.
  """
  @spec generate_ecdsa_key_pair(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, String.t()}
  def generate_ecdsa_key_pair(context_id, session_id, label, extractable \\ false) do
    case generate_key_pair(context_id, session_id, "ecdsa", 256, label, extractable) do
      {:ok, key_handles} ->
        result = Enum.into(key_handles, %{})
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate RSA key pair with specified parameters.
  """
  @spec generate_rsa_key_pair(String.t(), String.t(), String.t(), non_neg_integer(), boolean()) ::
          {:ok, map()} | {:error, String.t()}
  def generate_rsa_key_pair(context_id, session_id, label, key_size \\ 2048, extractable \\ false) do
    case generate_key_pair(context_id, session_id, "rsa", key_size, label, extractable) do
      {:ok, key_handles} ->
        result = Enum.into(key_handles, %{})
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sign data using ECDSA with SHA-256.
  """
  @spec ecdsa_sign(String.t(), String.t(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, String.t()}
  def ecdsa_sign(context_id, session_id, private_key_handle, data) do
    sign_data(context_id, session_id, private_key_handle, "ecdsa_sha256", data)
  end

  @doc """
  Sign data using RSA PKCS#1.
  """
  @spec rsa_sign(String.t(), String.t(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, String.t()}
  def rsa_sign(context_id, session_id, private_key_handle, data) do
    sign_data(context_id, session_id, private_key_handle, "rsa_pkcs", data)
  end

  @doc """
  Verify ECDSA signature with SHA-256.
  """
  @spec ecdsa_verify(String.t(), String.t(), non_neg_integer(), binary(), binary()) ::
          {:ok, boolean()} | {:error, String.t()}
  def ecdsa_verify(context_id, session_id, public_key_handle, data, signature) do
    verify_signature(context_id, session_id, public_key_handle, "ecdsa_sha256", data, signature)
  end

  @doc """
  Verify RSA PKCS#1 signature.
  """
  @spec rsa_verify(String.t(), String.t(), non_neg_integer(), binary(), binary()) ::
          {:ok, boolean()} | {:error, String.t()}
  def rsa_verify(context_id, session_id, public_key_handle, data, signature) do
    verify_signature(context_id, session_id, public_key_handle, "rsa_pkcs", data, signature)
  end

  @doc """
  Find all private keys in the token.
  """
  @spec find_private_keys(String.t(), String.t()) ::
          {:ok, [non_neg_integer()]} | {:error, String.t()}
  def find_private_keys(context_id, session_id) do
    template = [{"class", "private_key"}]
    find_objects(context_id, session_id, template)
  end

  @doc """
  Find all public keys in the token.
  """
  @spec find_public_keys(String.t(), String.t()) ::
          {:ok, [non_neg_integer()]} | {:error, String.t()}
  def find_public_keys(context_id, session_id) do
    template = [{"class", "public_key"}]
    find_objects(context_id, session_id, template)
  end

  @doc """
  Find keys by label.
  """
  @spec find_keys_by_label(String.t(), String.t(), String.t()) ::
          {:ok, [non_neg_integer()]} | {:error, String.t()}
  def find_keys_by_label(context_id, session_id, label) do
    template = [{"label", label}]
    find_objects(context_id, session_id, template)
  end

  @doc """
  Clean up session and context.
  """
  @spec cleanup(String.t(), String.t()) :: :ok
  def cleanup(context_id, session_id) do
    logout(context_id, session_id)
    close_session(context_id, session_id)
    finalize_library(context_id)
    :ok
  end
end
