defmodule LogflareWeb.Source.SearchLV do
  @moduledoc false
  alias Logflare.Google.BigQuery.{GenUtils, Query}
  alias Logflare.{Sources, Source, Logs, LogEvent}
  alias Logflare.Logs.Search
  alias Logflare.Logs.Search.SearchOpts
  alias LogflareWeb.SourceView
  use Phoenix.LiveView
  use TypedStruct

  def render(assigns) do
    Phoenix.View.render(SourceView, "search_frame.html", assigns)
  end

  def mount(%{source: source}, socket) do
    {:ok,
     assign(socket,
       query: nil,
       loading: false,
       log_events: [],
       source: source,
       partitions: nil
     )}
  end

  def handle_event("search", params, socket) do
    %{"search" => %{"q" => query}} = params

    send(self(), :search)

    {:noreply,
     assign(socket,
       query: query,
       result: "Searching...",
       loading: true
     )}
  end

  def default_partitions() do
    today = Date.utc_today() |> Timex.to_datetime("Etc/UTC")
    {today, today}
  end

  def handle_info(:search, socket) do
    {:ok, %{rows: log_events}} =
      SearchOpts
      |> struct(socket.assigns)
      |> Search.search()

    log_events =
      log_events
      |> Enum.map(&LogEvent.make_from_db(&1, %{source: socket.assigns.source}))
      |> Enum.sort_by(& &1.body.timestamp, &<=/2)

    {:noreply, assign(socket, loading: false, log_events: log_events)}
  end
end
