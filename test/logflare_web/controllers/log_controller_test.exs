defmodule LogflareWeb.LogControllerTest do
  @moduledoc false
  use LogflareWeb.ConnCase
  alias Logflare.Backends.Adaptor.WebhookAdaptor
  alias Logflare.Source.RecentLogsServer
  alias Logflare.Sources.Counters
  alias Logflare.Sources.RateCounters

  @valid %{"some" => "valid log entry", "event_message" => "hi!"}
  @valid_batch [
    %{"some" => "valid log entry", "event_message" => "hi!"},
    %{"some" => "valid log entry 2", "event_message" => "hi again!"}
  ]

  setup do
    Logflare.Sources.Counters
    |> stub(:increment, fn v -> v end)

    Logflare.SystemMetrics.AllLogsLogged
    |> stub(:increment, fn v -> v end)

    # mock goth behaviour
    Goth
    |> stub(:fetch, fn _mod -> {:ok, %Goth.Token{token: "auth-token"}} end)

    :ok
  end

  describe "v2 pipeline" do
    setup do
      user = insert(:user)
      source = insert(:source, user_id: user.id, v2_pipeline: true)
      _plan = insert(:plan, name: "Free")

      source_backend =
        insert(:source_backend, source_id: source.id, type: :webhook, config: %{url: "some url"})

      # stub out rate limiting logic for now
      # TODO: remove once rate limiting logic is refactored
      LogflareWeb.Plugs.RateLimiter
      |> stub(:call, fn x, _ -> x end)

      {:ok, source: source, user: user, source_backend: source_backend}
    end

    test "valid ingestion", %{conn: conn, source: source, user: user} do
      WebhookAdaptor
      |> expect(:ingest, fn _, _ -> :ok end)

      conn =
        conn
        |> put_req_header("x-api-key", user.api_key)
        |> post(Routes.log_path(conn, :create, source: source.token), @valid)

      assert json_response(conn, 200) == %{"message" => "Logged!"}
      :timer.sleep(1500)
    end
  end

  describe "v1 pipeline" do
    setup %{conn: conn} do
      insert(:plan, name: "Free")
      user = insert(:user)
      source = insert(:source, user: user)

      rls = %RecentLogsServer{source: source, source_id: source.token}
      start_supervised!(Counters)
      start_supervised!(RateCounters)
      start_supervised!({RecentLogsServer, rls})
      :timer.sleep(1000)

      # stub out rate limiting logic for now
      # TODO: remove once rate limiting logic is refactored
      LogflareWeb.Plugs.RateLimiter
      |> stub(:call, fn x, _ -> x end)

      Logflare.Logs
      |> expect(:broadcast, 1, fn le ->
        assert match?(@valid, le.body)
        assert le.body["event_message"] != nil
        assert Map.keys(le.body) |> length() == 4, inspect(Map.keys(le.body))

        le
      end)

      conn =
        conn
        |> put_req_header("x-api-key", user.api_key)

      {:ok, source: source, user: user, conn: conn}
    end

    test ":create ingestion", %{conn: conn, source: source} do
      conn =
        conn
        |> post(Routes.log_path(conn, :create, source: source.token), @valid)

      assert json_response(conn, 200) == %{"message" => "Logged!"}
    end

    test ":create ingestion batch with `batch` key", %{conn: conn, source: source} do
      conn =
        conn
        |> post(Routes.log_path(conn, :create, source: source.token), %{"batch" => @valid_batch})

      assert json_response(conn, 200) == %{"message" => "Logged!"}
    end

    test ":create ingestion batch with array body", %{conn: conn, source: source} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(Routes.log_path(conn, :create, source: source.token), Jason.encode!(@valid_batch))

      assert json_response(conn, 200) == %{"message" => "Logged!"}
    end

    test ":cloudflare ingestion", %{conn: new_conn, source: source} do
      path = Routes.log_path(new_conn, :cloudflare, source: source.token)

      assert new_conn |> post(path, @valid) |> json_response(200) == %{"message" => "Logged!"}

      assert new_conn
             |> post(path, %{batch: [@valid]})
             |> json_response(200) == %{
               "message" => "Logged!"
             }
    end
  end
end
