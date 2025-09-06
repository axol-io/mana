defmodule Blockchain.Utils.EnumHelpers do
  @moduledoc """
  Helper functions for Enum operations that are not in the standard library.
  """

  @doc """
  Unzips a list of 3-tuples into three separate lists.

  ## Examples

      iex> Blockchain.Utils.EnumHelpers.unzip3([{1, 2, 3}, {4, 5, 6}, {7, 8, 9}])
      {[1, 4, 7], [2, 5, 8], [3, 6, 9]}
      
      iex> Blockchain.Utils.EnumHelpers.unzip3([])
      {[], [], []}
  """
  @spec unzip3(list({any(), any(), any()})) :: {list(any()), list(any()), list(any())}
  def unzip3(list) when is_list(list) do
    Enum.reduce(list, {[], [], []}, fn {a, b, c}, {acc_a, acc_b, acc_c} ->
      {[a | acc_a], [b | acc_b], [c | acc_c]}
    end)
    |> then(fn {list_a, list_b, list_c} ->
      {Enum.reverse(list_a), Enum.reverse(list_b), Enum.reverse(list_c)}
    end)
  end
end
