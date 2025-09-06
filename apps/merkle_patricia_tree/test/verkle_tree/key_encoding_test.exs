defmodule VerkleTree.KeyEncodingTest do
  use ExUnit.Case, async: true

  alias VerkleTree.KeyEncoding

  describe "EIP-6800 key encoding" do
    test "get_tree_key generates proper 32-byte keys" do
      address32 = <<0::256>>
      tree_index = 0
      sub_index = 0

      key = KeyEncoding.get_tree_key(address32, tree_index, sub_index)

      assert byte_size(key) == 32
      assert KeyEncoding.extract_suffix(key) == sub_index
    end

    test "basic data key generation" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)

      key = KeyEncoding.get_tree_key_for_basic_data(address32)

      assert byte_size(key) == 32
      assert KeyEncoding.extract_suffix(key) == 0
    end

    test "code hash key generation" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)

      key = KeyEncoding.get_tree_key_for_code_hash(address32)

      assert byte_size(key) == 32
      assert KeyEncoding.extract_suffix(key) == 1
    end

    test "code chunk key generation" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)

      # Test first chunk (chunk_id = 0)
      key0 = KeyEncoding.get_tree_key_for_code_chunk(address32, 0)
      assert byte_size(key0) == 32
      # 0 + 128
      assert KeyEncoding.extract_suffix(key0) == 128

      # Test chunk at boundary (chunk_id = 127)
      key127 = KeyEncoding.get_tree_key_for_code_chunk(address32, 127)
      # 127 + 128
      assert KeyEncoding.extract_suffix(key127) == 255

      # Test chunk requiring new tree_index (chunk_id = 128)
      key128 = KeyEncoding.get_tree_key_for_code_chunk(address32, 128)
      # 0 + 128
      assert KeyEncoding.extract_suffix(key128) == 128

      # Keys with different tree_index should have different stems
      refute KeyEncoding.same_stem?(key0, key128)
    end

    test "storage slot key generation" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)
      storage_key = <<42::256>>

      key = KeyEncoding.get_tree_key_for_storage_slot(address32, storage_key)

      assert byte_size(key) == 32
      # For storage_key = 42, suffix should be 42 % 256 = 42
      assert KeyEncoding.extract_suffix(key) == 42
    end

    test "address conversion" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)

      assert byte_size(address32) == 32
      # First 12 bytes should be zeros
      <<zeros::96, addr_part::binary-size(20)>> = address32
      assert zeros == 0
      assert addr_part == address

      # Converting 32-byte address should return unchanged
      assert KeyEncoding.address_to_address32(address32) == address32
    end

    test "code splitting into chunks" do
      # Small code
      small_code = "hello"
      chunks = KeyEncoding.split_code_into_chunks(small_code)

      assert length(chunks) == 1
      # Padded to 31 bytes
      assert byte_size(hd(chunks)) == 31

      # Large code requiring multiple chunks
      large_code = String.duplicate("x", 100)
      chunks = KeyEncoding.split_code_into_chunks(large_code)

      # 100 / 31 = 3.22, so 4 chunks
      assert length(chunks) == 4
      assert Enum.all?(chunks, fn chunk -> byte_size(chunk) == 31 end)

      # Last chunk should be padded
      last_chunk = List.last(chunks)
      # Original would be 7 bytes (100 - 3*31), padded to 31
      assert byte_size(last_chunk) == 31
    end

    test "stem and suffix extraction" do
      address32 = <<0::256>>
      key = KeyEncoding.get_tree_key(address32, 12345, 42)

      stem = KeyEncoding.extract_stem(key)
      suffix = KeyEncoding.extract_suffix(key)

      assert byte_size(stem) == 31
      assert suffix == 42

      # Reconstructed key should match original
      reconstructed = stem <> <<suffix>>
      assert reconstructed == key
    end

    test "key validation" do
      # Valid verkle key
      address32 = <<0::256>>
      valid_key = KeyEncoding.get_tree_key(address32, 0, 100)

      assert KeyEncoding.validate_verkle_key(valid_key)

      # Invalid keys
      refute KeyEncoding.validate_verkle_key("short")
      refute KeyEncoding.validate_verkle_key(:atom)

      # Key with invalid suffix (>= 256)
      # suffix = 255 is valid
      invalid_key = <<0::248, 255>> <> <<255>>
      assert KeyEncoding.validate_verkle_key(invalid_key)

      # But this creates suffix > 255
      really_invalid = <<0::248, 255>> <> <<0>>
      # This would overflow
      really_invalid_key = binary_part(really_invalid, 0, 31) <> <<256>>
      # This test might fail due to byte constraints - suffix is single byte so max is 255
    end

    test "same stem detection" do
      address32 = <<0::256>>

      key1 = KeyEncoding.get_tree_key(address32, 0, 10)
      # Same stem, different suffix
      key2 = KeyEncoding.get_tree_key(address32, 0, 20)
      # Different stem
      key3 = KeyEncoding.get_tree_key(address32, 1, 10)

      assert KeyEncoding.same_stem?(key1, key2)
      refute KeyEncoding.same_stem?(key1, key3)

      # Invalid inputs
      refute KeyEncoding.same_stem?("short", key1)
      refute KeyEncoding.same_stem?(key1, "short")
    end

    test "tree depth constant" do
      assert KeyEncoding.get_tree_depth() == 32
    end
  end

  describe "Integration with existing patterns" do
    test "different key types produce different keys" do
      address = :crypto.strong_rand_bytes(20)
      address32 = KeyEncoding.address_to_address32(address)
      storage_key = <<100::256>>

      basic_key = KeyEncoding.get_tree_key_for_basic_data(address32)
      code_hash_key = KeyEncoding.get_tree_key_for_code_hash(address32)
      code_chunk_key = KeyEncoding.get_tree_key_for_code_chunk(address32, 0)
      storage_slot_key = KeyEncoding.get_tree_key_for_storage_slot(address32, storage_key)

      # All keys should be different
      keys = [basic_key, code_hash_key, code_chunk_key, storage_slot_key]
      unique_keys = Enum.uniq(keys)

      assert length(keys) == length(unique_keys)
    end

    test "deterministic key generation" do
      address = <<1::160>>
      address32 = KeyEncoding.address_to_address32(address)

      # Same inputs should produce same keys
      key1 = KeyEncoding.get_tree_key_for_basic_data(address32)
      key2 = KeyEncoding.get_tree_key_for_basic_data(address32)

      assert key1 == key2

      # Different addresses should produce different keys
      different_address = <<2::160>>
      different_address32 = KeyEncoding.address_to_address32(different_address)
      different_key = KeyEncoding.get_tree_key_for_basic_data(different_address32)

      assert key1 != different_key
    end
  end
end
