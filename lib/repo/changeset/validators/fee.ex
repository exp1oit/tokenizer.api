defmodule Repo.Changeset.Validators.Fee do
  @moduledoc """
  This helper validates phone numbers in international format (with `+:country_code`).
  """
  import Ecto.Changeset
  alias Decimal, as: D

  defstruct fix: nil, percent: nil, min: 0, max: :infinity

  def validate_fee(changeset, amount_field, fee_field, [percent: percent, fix: fix, min: min, max: max] = opts) do
    validate_change changeset, amount_field, {:fee, opts}, fn _, value ->
      value
      |> calculate(percent, fix, min, max)
      |> get_result(get_field(changeset, fee_field), fee_field)
    end
  end

  defp get_result(_valid_fee, nil, _fee_field), do: []
  defp get_result(valid_fee, transfer_fee, fee_field) do
    case D.cmp(valid_fee, transfer_fee) do
      :eq -> []
      _ -> [{fee_field, {"is invalid, must be #{valid_fee}", [validation: :fee]}}]
    end
  end

  def calculate(amount, percent, fix, min, max) do
    amount
    |> calculate_body(percent, fix)
    |> apply_limits(min, max)
  end

  defp calculate_body(amount, percent, fix) do
    prepared_percent =
      percent
      |> D.new()
      |> D.div(D.new(100))
      |> D.round(2)

    amount
    |> D.mult(prepared_percent)
    |> D.add(D.new(fix))
    |> D.round(2)
  end

  defp apply_limits(body, min, :infinity) do
    D.max(body, D.new(min))
  end

  defp apply_limits(body, min, max) do
    D.max(D.min(body, D.new(max)), D.new(min))
  end
end
