defmodule Logflare.Source.RecentLogsServer do
  @moduledoc """
  Manages the individual table for the source. Limits things in the table to 1000. Manages TTL for
  things in the table. Handles loading the table from the disk if found on startup.
  """
  use Publicist
  use TypedStruct

  typedstruct do
    field :source_id, atom(), enforce: true
    field :notifications_every, integer(), default: 60_000
    field :inserts_since_boot, integer(), default: 0
    field :bigquery_project_id, atom()
    field :bigquery_dataset_id, binary()
  end

  use GenServer

  alias Logflare.Sources.Counters
  alias Logflare.Google.{BigQuery, BigQuery.GenUtils}
  alias Number.Delimit
  alias Logflare.Source.BigQuery.{Schema, Pipeline, Buffer}
  alias Logflare.Source.{Data, EmailNotificationServer, TextNotificationServer, RateCounterServer}
  alias Logflare.LogEvent, as: LE
  alias Logflare.Source
  alias Logflare.Logs.SearchQueryExecutor
  alias Logflare.Cluster
  alias __MODULE__, as: RLS

  require Logger

  # one month
  @prune_timer 1_000
  def start_link(%__MODULE__{source_id: source_id} = rls) when is_atom(source_id) do
    GenServer.start_link(__MODULE__, rls, name: source_id)
  end

  ## Client
  @spec init(RLS.t()) :: {:ok, RLS.t(), {:continue, :boot}}
  def init(rls) do
    Process.flag(:trap_exit, true)
    prune()

    {:ok, rls, {:continue, :boot}}
  end

  def push(source_id, %LE{} = log_event) do
    GenServer.cast(source_id, {:push, source_id, log_event})
  end

  ## Server

  def handle_continue(:boot, %__MODULE__{source_id: source_id} = rls) when is_atom(source_id) do
    %{
      user_id: user_id,
      bigquery_table_ttl: bigquery_table_ttl,
      bigquery_project_id: bigquery_project_id,
      bigquery_dataset_location: bigquery_dataset_location,
      bigquery_dataset_id: bigquery_dataset_id
    } = GenUtils.get_bq_user_info(source_id)

    # Logger.info("bigquery_table_ttl: #{bigquery_table_ttl},
    # bigquery_project_id: #{bigquery_project_id},
    # bigquery_dataset_location: #{bigquery_dataset_location},
    # bigquery_dataset_id: #{bigquery_dataset_id}")

    BigQuery.init_table!(
      user_id,
      source_id,
      bigquery_project_id,
      bigquery_table_ttl,
      bigquery_dataset_location,
      bigquery_dataset_id
    )

    table_args = [:named_table, :ordered_set, :public]
    :ets.new(source_id, table_args)

    rls = %{
      rls
      | bigquery_project_id: bigquery_project_id,
        bigquery_dataset_id: bigquery_dataset_id
    }

    children = [
      {RateCounterServer, rls},
      {EmailNotificationServer, rls},
      {TextNotificationServer, rls},
      {Buffer, rls},
      {Schema, rls},
      {Pipeline, rls},
      {SearchQueryExecutor, rls}
    ]

    Supervisor.start_link(children, strategy: :one_for_all)

    Task.Supervisor.start_child(Logflare.TaskSupervisor, fn ->
      load_init_log_message(source_id, bigquery_project_id)
    end)

    Logger.info("RecentLogsServer started: #{source_id}")
    {:noreply, rls}
  end

  def handle_cast({:push, source_id, %LE{ingested_at: inj_at, sys_uint: sys_uint} = le}, state) do
    timestamp = inj_at |> Timex.to_datetime() |> DateTime.to_unix(:microsecond)
    :ets.insert(source_id, {{timestamp, sys_uint, 0}, le})
    {:noreply, state}
  end

  def handle_info({:stop_please, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(:prune, %__MODULE__{source_id: source_id} = state) do
    count = Data.get_ets_count(source_id)

    case count > 100 do
      true ->
        for _log <- 101..count do
          log = :ets.first(source_id)

          if :ets.delete(source_id, log) == true do
            Counters.decriment(source_id)
          end
        end

        prune()
        {:noreply, state}

      false ->
        prune()
        {:noreply, state}
    end
  end

  def terminate(reason, %__MODULE__{} = state) do
    # Do Shutdown Stuff
    Logger.info("Going Down: #{state.source_id}")
    reason
  end

  ## Private Functions

  defp load_init_log_message(source_id, bigquery_project_id) do
    log_count = Data.get_log_count(source_id, bigquery_project_id)

    if log_count > 0 do
      message =
        "Initialized. Waiting for new events. #{Delimit.number_to_delimited(log_count)} available to explore & search."

      log_event = LE.make(%{"message" => message}, %{source: %Source{token: source_id}})
      push(source_id, log_event)

      Source.ChannelTopics.broadcast_new(log_event)
    end
  end

  defp prune() do
    Process.send_after(self(), :prune, @prune_timer)
  end
end
