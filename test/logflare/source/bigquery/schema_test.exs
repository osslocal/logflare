defmodule Logflare.Source.BigQuery.SchemaTest do
  @moduledoc false
  use Logflare.DataCase
  alias Logflare.Source.BigQuery.Schema
  alias Logflare.Google.BigQuery.SchemaUtils

  test "next_update_ts/1" do
    next_update = Schema.next_update_ts(6) |> trunc()
    assert String.length("#{next_update}") == String.length("#{System.system_time(:millisecond)}")
    seconds = (next_update - System.system_time(:millisecond)) / 1000
    assert seconds <= 10
    assert seconds > 9
  end

  test "updates correctly" do
    user = insert(:user)
    source = insert(:source, user: user)
    schema = TestUtils.default_bq_schema()

    insert(:source_schema,
      source: source,
      source_id: source.id,
      bigquery_schema: schema,
      schema_flat_map: SchemaUtils.bq_schema_to_flat_typemap(schema)
    )

    test_pid = self()

    # mock
    GoogleApi.BigQuery.V2.Api.Tables
    |> expect(:bigquery_tables_patch, 1, fn _conn,
                                            _project_id,
                                            _dataset_id,
                                            _table_name,
                                            [body: body] ->
      schema = body.schema

      assert %_{name: "test", type: "INTEGER"} =
               TestUtils.get_bq_field_schema(schema, "metadata.test")

      send(test_pid, :ok)
      {:ok, %{}}
    end)

    Logflare.Mailer
    |> expect(:deliver, 1, fn _ -> :ok end)

    pid =
      start_supervised!(
        {Schema,
         [
           source: source,
           plan: %{limit_source_fields_limit: 500},
           bigquery_project_id: "some-id",
           bigquery_dataset_id: "some-id"
         ]}
      )

    le = build(:log_event, source: source, metadata: %{"test" => 123})
    assert :ok = Schema.update(pid, le)
    assert_receive :ok, 500
    # subsequent updates do not increase mock count
    le = build(:log_event, source: source, metadata: %{"change" => 123})
    assert :ok = Schema.update(pid, le)
  end
end
