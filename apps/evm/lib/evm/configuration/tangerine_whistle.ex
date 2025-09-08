defmodule EVM.Configuration.TangerineWhistle do
  alias EVM.Configuration.Homestead

  use EVM.Configuration,
    fallback_config: Homestead,
    overrides: %{
      extcodesize_cost: 700,
      extcodecopy_cost: 700,
      balance_cost: 400,
      sload_cost: 200,
      call_cost: 700,
      selfdestruct_cost: 5_000,
      new_account_destruction_cost: 25_000,
      should_fail_nested_operation_lack_of_gas: false
    }

  @impl true
  def selfdestruct_cost(_config, new_account: false), do: 5000

  def selfdestruct_cost(_config, new_account: true) do
    5000 + 25000  # selfdestruct_cost + new_account_destruction_cost
  end

  @impl true
  def limit_contract_code_size?(config, _size) do
    config.limit_contract_code_size
  end
end
