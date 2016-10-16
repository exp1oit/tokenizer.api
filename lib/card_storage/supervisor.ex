defmodule Tokenizer.CardStorage.Supervisor do
  @moduledoc """
  This supervisor allows to asynchronously start workers and maintain they availability.
  Polling is done on AMQP level by `prefetch_count` option.
  """
  use Supervisor
  require Logger
  alias Tokenizer.DB.Models.SenderCard
  alias Tokenizer.CardStorage.Encryptor

  @token_prefix "token"

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Save card to a GenServer process that will allow to read it's data only once.

  Card data is encrypted in two rounds:
    1. By user-token that is generated by this Supervisor
    2. By key that is set in environment config.

  In this way we make sure that card data can't be decoded without server-key if user-key is stolen,
  and by user-key if server is hacked.
  """
  def save_card(%SenderCard{number: card_number} = card) do
    token = card_number
    |> generate_token

    card_data = card
    |> Poison.encode!
    |> Encryptor.encrypt(get_encryption_keys(token))

    child_name = get_card_process_name(token)
    expires_in = Confex.get(:tokenizer_api, :token_expiration_time)

    {:ok, _pid} = Supervisor.start_child(__MODULE__, [[
      card_data: card_data,
      expires_in: expires_in,
      name: child_name]])

    expires_at = Timex.now
    |> Timex.shift(microseconds: expires_in)

    {:ok, %{token: token, token_expires_at: expires_at}}
  end

  @doc """
  Get saved card data.

  This method requires user card token to find card process and decrypt card data.

  It can return:
    * `{:error, reason}` - when card decryption is impossible (`:invalid_key_or_signature`)
    or card is not found (`:card_not_found`).
    * `{:ok, card}` - where `card` is decrypted card details.

  For a single card this method can be called only once, because card data will destroy itself after decryption.
  """
  def get_card(token) do
    token
    |> get_card_process_name
    |> Process.whereis
    |> get_card_data(token)
  end

  defp get_card_data(nil, _token) do
    {:error, :card_not_found}
  end

  defp get_card_data(card_pid, token) do
    message = card_pid
    |> Tokenizer.CardStorage.Card.get_data
    |> Encryptor.decrypt(get_decryption_keys(token))

    case message do
      {:error, reason} ->
        {:error, reason}
      _ ->
        card = message
        |> Poison.decode!
        |> to_struct(SenderCard)

        {:ok, card}
    end
  end

  defp to_struct(attrs, kind) do
    struct = struct(kind)
    Enum.reduce Map.to_list(struct), struct, fn {k, _}, acc ->
      case Map.fetch(attrs, Atom.to_string(k)) do
        {:ok, v} -> %{acc | k => v}
        :error -> acc
      end
    end
  end

  @doc """
  Generate card token for a given card number or last 4 digits of card number.
  """
  def generate_token(card_number) when byte_size(card_number) > 4 do
    card_number
    |> String.slice(-4..-1)
    |> generate_token
  end

  def generate_token(last4) when is_binary(last4) do
    salt = {last4, :os.timestamp()}
    |> :erlang.term_to_binary

    id = :sha
    |> :crypto.hash(salt <> :crypto.strong_rand_bytes(16))
    |> Base.encode16
    |> String.downcase

    @token_prefix <> "-" <> last4 <> "-" <> id
  end

  defp get_encryption_keys(<<@token_prefix, "-", _last4::bytes-size(4), "-", user_key::bytes>>) do
    [
      user_key,
      Confex.get(:tokenizer_api, :card_encryption_key)
    ]
  end

  defp get_decryption_keys(<<@token_prefix, "-", _last4::bytes-size(4), "-", _user_key::bytes>> = token) do
    token
    |> get_encryption_keys
    |> Enum.reverse
  end

  def get_card_process_name(token) do
    String.to_atom("Cards." <> token)
  end

  @doc false
  def init(_) do
    children = [
      supervisor(Tokenizer.CardStorage.Card, [], restart: :transient)
    ]

    supervise(children, strategy: :simple_one_for_one)
  end
end
