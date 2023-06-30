defmodule Logflare.Google.BigQuery.GenUtils do
  @moduledoc """
  Generic utils for BigQuery.
  """
  require Logger

  alias Logflare.JSON
  alias Logflare.{Sources, Users}
  alias Logflare.{Source, User}
  alias GoogleApi.BigQuery.V2.Connection

  @table_ttl 604_800_000
  @default_dataset_location "US"
  defp env_project_id, do: Application.get_env(:logflare, Logflare.Google)[:project_id]

  defp env_default_table_name_append,
    do:
      Application.get_env(:logflare, Logflare.Google)[:dataset_id_append] ||
        ""

  @spec get_project_id(atom()) :: String.t()
  def get_project_id(source_id) when is_atom(source_id) do
    %Source{user_id: user_id} = Sources.get_by(token: source_id)
    %User{bigquery_project_id: project_id} = Users.get_by(id: user_id)

    project_id || env_project_id()
  end

  @spec get_bq_user_info(atom) :: map
  def get_bq_user_info(source_id) when is_atom(source_id) do
    %Source{user_id: user_id, bigquery_table_ttl: ttl} = Sources.get_by(token: source_id)

    %User{
      id: user_id,
      sources: _sources,
      bigquery_project_id: project_id,
      bigquery_dataset_location: dataset_location,
      bigquery_dataset_id: dataset_id
    } = Users.get_by(id: user_id)

    new_ttl =
      cond do
        is_nil(project_id) -> @table_ttl
        is_nil(ttl) -> @table_ttl
        true -> ttl * 86_400_000
      end

    new_project_id = project_id || env_project_id()
    new_dataset_location = dataset_location || @default_dataset_location
    new_dataset_id = dataset_id || "#{user_id}" <> env_default_table_name_append()

    %{
      user_id: user_id,
      bigquery_table_ttl: new_ttl,
      bigquery_project_id: new_project_id,
      bigquery_dataset_location: new_dataset_location,
      bigquery_dataset_id: new_dataset_id
    }
  end

  @spec format_table_name(atom) :: String.t()
  def format_table_name(source) do
    string = Atom.to_string(source)
    String.replace(string, "-", "_")
  end

  @doc """
  Dynamically builds a Tesla client connection. Switches adapter at runtime based on first arg.

  Uses `Logflare.FinchDefault` by default
  """
  @typep conn_type :: :ingest | :query | :default
  @spec get_conn(conn_type()) :: Tesla.Env.client()
  def get_conn(conn_type \\ :default) do
    Logflare.Goth
    |> Goth.fetch()
    |> then(fn
      {:ok, %Goth.Token{} = goth} ->
        Connection.new(goth.token)

      {:error, reason} ->
        Logger.error("Goth error!", error_string: inspect(reason))
        # This is going to give us an unauthorized connection but we are handling it downstream.
        Connection.new("")
    end)
    # dynamically set tesla adapter
    |> Map.update!(:adapter, fn _value -> build_tesla_adapter_call(conn_type) end)
  end

  # copy over runtime adapter building from Tesla.client/2
  # https://github.com/elixir-tesla/tesla/blob/v1.7.0/lib/tesla/builder.ex#L206
  defp build_tesla_adapter_call(:ingest) do
    Tesla.client([], {Tesla.Adapter.Finch, name: Logflare.FinchIngest, receive_timeout: 15_000}).adapter
  end

  defp build_tesla_adapter_call(:query) do
    Tesla.client(
      [],
      {Tesla.Adapter.Finch, name: Logflare.FinchQuery, receive_timeout: 60_000}
    ).adapter
  end

  # use adapter in config.exs
  defp build_tesla_adapter_call(_), do: nil

  @spec get_account_id(atom) :: String.t()
  def get_account_id(source_id) when is_atom(source_id) do
    %Logflare.Source{user_id: account_id} = Sources.get_by(token: source_id)
    "#{account_id}"
  end

  @spec maybe_parse_google_api_result({:ok, any()} | {:error, any()}) ::
          {:ok, any()} | {:error, any()}

  def maybe_parse_google_api_result({:error, %Tesla.Env{} = teslaenv}) do
    {:error, teslaenv}
  end

  def maybe_parse_google_api_result(x), do: x

  @spec get_tesla_error_message(:emfile | :timeout | :closed | Tesla.Env.t()) :: String.t()
  def get_tesla_error_message(%Tesla.Env{} = message) do
    case JSON.decode(message.body) do
      {:ok, body} ->
        body["error"]["message"]

      {:error, data} ->
        inspect(data)
    end
  end

  def get_tesla_error_message(:emfile), do: "emfile"
  def get_tesla_error_message(:timeout), do: "timeout"
  def get_tesla_error_message(:closed), do: "closed"
  def get_tesla_error_message(message), do: inspect(message)

  def format_key(label) when is_binary(label) do
    # https://cloud.google.com/resource-manager/docs/creating-managing-labels?_ga=2.5645051.-99470436.1587500458#requirements

    label
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.slice(0, 62)
  end

  def format_key(label) when is_integer(label), do: label |> Integer.to_string() |> format_key()
  def format_key(label) when is_atom(label), do: label |> Atom.to_string() |> format_key()
end
