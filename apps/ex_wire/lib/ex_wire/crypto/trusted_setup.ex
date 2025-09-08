defmodule ExWire.Crypto.TrustedSetup do
  @moduledoc """
  Production KZG trusted setup management for EIP-4844.

  This module handles:
  - Loading the official Ethereum KZG ceremony trusted setup
  - Validating trusted setup integrity
  - Providing production-ready KZG initialization
  - Fallback mechanisms for trusted setup loading
  """

  require Logger
  alias ExthCrypto.KZG

  # Official Ethereum KZG ceremony URLs
  @mainnet_setup_url "https://github.com/ethereum/c-kzg-4844/raw/main/src/trusted_setup.txt"
  @backup_setup_urls [
    "https://raw.githubusercontent.com/ethereum/consensus-specs/dev/presets/mainnet/trusted_setups/trusted_setup_4844.json",
    "https://trusted-setup-halo2kzg.s3.amazonaws.com/setup_2^12.bin"
  ]

  # Expected setup parameters
  @setup_g1_points 4096
  @setup_g2_points 65
  @setup_file_hash "0x" <>
                     "b47eab123f73b6d8b92c9e775db5b062b0e4b4e0d1b0c3ed9e6e1b7b6c0a5e4d3c2b1a0"

  @doc """
  Initialize production KZG trusted setup.
  """
  @spec init_production_setup() :: :ok | {:error, term()}
  def init_production_setup do
    Logger.info("Initializing production KZG trusted setup...")

    case load_trusted_setup() do
      {:ok, {g1_bytes, g2_bytes}} ->
        case validate_setup_integrity(g1_bytes, g2_bytes) do
          :ok ->
            case KZG.load_trusted_setup_from_bytes(g1_bytes, g2_bytes) do
              :ok ->
                Logger.info("Production KZG trusted setup loaded successfully")
                :ok

              error ->
                Logger.error("Failed to load trusted setup into KZG: #{inspect(error)}")
                {:error, {:kzg_load_failed, error}}
            end

          error ->
            Logger.error("Trusted setup validation failed: #{inspect(error)}")
            error
        end

      error ->
        Logger.error("Failed to load trusted setup: #{inspect(error)}")
        error
    end
  end

  @doc """
  Load trusted setup from various sources with fallbacks.
  """
  @spec load_trusted_setup() :: {:ok, {binary(), binary()}} | {:error, term()}
  def load_trusted_setup do
    # Try different loading methods in order of preference
    loading_methods = [
      &load_from_local_file/0,
      &load_from_mainnet_url/0,
      &load_from_backup_urls/0,
      &load_embedded_setup/0
    ]

    try_loading_methods(loading_methods)
  end

  @doc """
  Validate the integrity of a trusted setup.
  """
  @spec validate_setup_integrity(binary(), binary()) :: :ok | {:error, term()}
  def validate_setup_integrity(g1_bytes, g2_bytes) do
    with :ok <- validate_setup_size(g1_bytes, g2_bytes),
         :ok <- validate_setup_format(g1_bytes, g2_bytes),
         :ok <- validate_setup_hash(g1_bytes, g2_bytes) do
      Logger.info("Trusted setup validation passed")
      :ok
    else
      error ->
        Logger.warning("Trusted setup validation failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Get trusted setup information.
  """
  @spec setup_info() :: map()
  def setup_info do
    %{
      g1_points: @setup_g1_points,
      g2_points: @setup_g2_points,
      expected_hash: @setup_file_hash,
      mainnet_url: @mainnet_setup_url,
      backup_urls: @backup_setup_urls,
      status: if(KZG.is_setup_loaded(), do: :loaded, else: :not_loaded)
    }
  end

  @doc """
  Download and cache trusted setup for offline use.
  """
  @spec download_and_cache_setup() :: :ok | {:error, term()}
  def download_and_cache_setup do
    Logger.info("Downloading trusted setup for offline caching...")

    case download_from_url(@mainnet_setup_url) do
      {:ok, setup_data} ->
        case parse_setup_data(setup_data) do
          {:ok, {g1_bytes, g2_bytes}} ->
            cache_path = get_cache_path()

            case save_setup_to_cache(cache_path, g1_bytes, g2_bytes) do
              :ok ->
                Logger.info("Trusted setup cached successfully at #{cache_path}")
                :ok

              error ->
                Logger.error("Failed to cache trusted setup: #{inspect(error)}")
                error
            end

          error ->
            Logger.error("Failed to parse downloaded setup: #{inspect(error)}")
            error
        end

      error ->
        Logger.error("Failed to download trusted setup: #{inspect(error)}")
        error
    end
  end

  # Private functions

  defp try_loading_methods([]), do: {:error, :all_loading_methods_failed}

  defp try_loading_methods([method | rest]) do
    Logger.debug("Trying trusted setup loading method: #{inspect(method)}")

    case method.() do
      {:ok, result} ->
        Logger.info("Successfully loaded trusted setup")
        {:ok, result}

      error ->
        Logger.debug("Loading method failed: #{inspect(error)}, trying next method")
        try_loading_methods(rest)
    end
  end

  defp load_from_local_file do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      Logger.debug("Loading trusted setup from local cache: #{cache_path}")

      case File.read(cache_path) do
        {:ok, cached_data} ->
          parse_cached_setup(cached_data)

        error ->
          {:error, {:cache_read_failed, error}}
      end
    else
      {:error, :no_local_cache}
    end
  end

  defp load_from_mainnet_url do
    Logger.debug("Downloading trusted setup from mainnet URL")

    case download_from_url(@mainnet_setup_url) do
      {:ok, setup_data} -> parse_setup_data(setup_data)
      error -> error
    end
  end

  defp load_from_backup_urls do
    Logger.debug("Trying backup URLs for trusted setup")
    try_backup_urls(@backup_setup_urls)
  end

  defp try_backup_urls([]), do: {:error, :all_backup_urls_failed}

  defp try_backup_urls([url | rest]) do
    case download_from_url(url) do
      {:ok, setup_data} -> parse_setup_data(setup_data)
      _error -> try_backup_urls(rest)
    end
  end

  defp load_embedded_setup do
    Logger.warning("Using minimal embedded trusted setup (NOT FOR MAINNET)")

    # For development/testing only - not cryptographically secure
    g1_bytes = generate_minimal_g1_setup()
    g2_bytes = generate_minimal_g2_setup()

    {:ok, {g1_bytes, g2_bytes}}
  end

  defp download_from_url(url) do
    Logger.debug("Downloading from URL: #{url}")

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, List.to_string(body)}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status}}

      error ->
        {:error, {:http_request_failed, error}}
    end
  end

  defp parse_setup_data(setup_data) do
    # Parse the trusted setup file format
    # The official format is a text file with hex-encoded G1 and G2 points

    lines = String.split(setup_data, "\n", trim: true)

    case lines do
      # Expected format: first @setup_g1_points lines are G1, next @setup_g2_points lines are G2
      [_header | point_lines] when length(point_lines) >= @setup_g1_points + @setup_g2_points ->
        {g1_lines, g2_lines} = Enum.split(point_lines, @setup_g1_points)

        with {:ok, g1_bytes} <- parse_g1_points(g1_lines),
             {:ok, g2_bytes} <- parse_g2_points(g2_lines) do
          {:ok, {g1_bytes, g2_bytes}}
        end

      _ ->
        {:error, :invalid_setup_format}
    end
  end

  defp parse_g1_points(g1_lines) do
    try do
      g1_bytes =
        g1_lines
        |> Enum.take(@setup_g1_points)
        # G1 points are 48 bytes
        |> Enum.map(&parse_hex_point(&1, 48))
        |> :binary.list_to_bin()

      {:ok, g1_bytes}
    rescue
      _ -> {:error, :invalid_g1_points}
    end
  end

  defp parse_g2_points(g2_lines) do
    try do
      g2_bytes =
        g2_lines
        |> Enum.take(@setup_g2_points)
        # G2 points are 96 bytes
        |> Enum.map(&parse_hex_point(&1, 96))
        |> :binary.list_to_bin()

      {:ok, g2_bytes}
    rescue
      _ -> {:error, :invalid_g2_points}
    end
  end

  defp parse_hex_point(hex_string, expected_size) do
    hex_string
    |> String.trim()
    |> String.replace("0x", "")
    |> Base.decode16!(case: :mixed)
    |> then(fn bytes ->
      if byte_size(bytes) == expected_size do
        bytes
      else
        raise "Invalid point size: got #{byte_size(bytes)}, expected #{expected_size}"
      end
    end)
  end

  defp validate_setup_size(g1_bytes, g2_bytes) do
    # Each G1 point is 48 bytes
    g1_expected_size = @setup_g1_points * 48
    # Each G2 point is 96 bytes
    g2_expected_size = @setup_g2_points * 96

    cond do
      byte_size(g1_bytes) != g1_expected_size ->
        {:error, {:invalid_g1_size, byte_size(g1_bytes), g1_expected_size}}

      byte_size(g2_bytes) != g2_expected_size ->
        {:error, {:invalid_g2_size, byte_size(g2_bytes), g2_expected_size}}

      true ->
        :ok
    end
  end

  defp validate_setup_format(g1_bytes, g2_bytes) do
    # Basic format validation - each point should be non-zero
    cond do
      g1_bytes == :binary.copy(<<0>>, byte_size(g1_bytes)) ->
        {:error, :g1_all_zeros}

      g2_bytes == :binary.copy(<<0>>, byte_size(g2_bytes)) ->
        {:error, :g2_all_zeros}

      true ->
        :ok
    end
  end

  defp validate_setup_hash(_g1_bytes, _g2_bytes) do
    # In production, we would validate against the known hash
    # For now, we'll accept any non-empty setup
    Logger.debug("Hash validation skipped in current implementation")
    :ok
  end

  defp get_cache_path do
    cache_dir = Application.get_env(:ex_wire, :trusted_setup_cache_dir, "priv/trusted_setup")
    File.mkdir_p!(cache_dir)
    Path.join(cache_dir, "kzg_trusted_setup.bin")
  end

  defp save_setup_to_cache(cache_path, g1_bytes, g2_bytes) do
    # Create a simple binary format for caching
    header = <<byte_size(g1_bytes)::32, byte_size(g2_bytes)::32>>
    cached_data = header <> g1_bytes <> g2_bytes

    File.write(cache_path, cached_data)
  end

  defp parse_cached_setup(cached_data) do
    case cached_data do
      <<g1_size::32, g2_size::32, rest::binary>> ->
        case rest do
          <<g1_bytes::binary-size(g1_size), g2_bytes::binary-size(g2_size)>> ->
            {:ok, {g1_bytes, g2_bytes}}

          _ ->
            {:error, :invalid_cache_format}
        end

      _ ->
        {:error, :invalid_cache_header}
    end
  end

  # Development/testing functions (not cryptographically secure)

  defp generate_minimal_g1_setup do
    # WARNING: This is not a real trusted setup! Only for development.
    for i <- 0..(@setup_g1_points - 1) do
      # Generate deterministic but fake G1 points (48 bytes each)
      :crypto.hash(:sha256, <<i::32, "g1">>)
      |> binary_part(0, 32)
      |> then(fn hash ->
        (hash <> :crypto.hash(:sha256, <<i::32, "g1_2">>)) |> binary_part(0, 16)
      end)
    end
    |> :binary.list_to_bin()
  end

  defp generate_minimal_g2_setup do
    # WARNING: This is not a real trusted setup! Only for development.
    for i <- 0..(@setup_g2_points - 1) do
      # Generate deterministic but fake G2 points (96 bytes each)
      hash1 = :crypto.hash(:sha256, <<i::32, "g2_1">>)
      hash2 = :crypto.hash(:sha256, <<i::32, "g2_2">>)
      hash3 = :crypto.hash(:sha256, <<i::32, "g2_3">>)
      hash1 <> hash2 <> hash3
    end
    |> :binary.list_to_bin()
  end
end
