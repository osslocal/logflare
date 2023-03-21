defmodule Logflare.SingleTenantTest do
  @moduledoc false
  use Logflare.DataCase
  alias Logflare.SingleTenant
  alias Logflare.Billing
  alias Logflare.Users
  alias Logflare.User
  alias Logflare.Billing.Plan
  alias Logflare.Sources
  alias Logflare.Endpoints

  describe "single tenant mode" do
    TestUtils.setup_single_tenant()

    test "create_default_plan/0 creates default enterprise plan if not present" do
      assert {:ok, plan} = SingleTenant.create_default_plan()
      assert plan.name == "Enterprise"
      assert {:error, :already_created} = SingleTenant.create_default_plan()
    end

    test "get_default_user/0" do
      assert {:ok, _plan} = SingleTenant.create_default_plan()
      assert {:ok, _user} = SingleTenant.create_default_user()
      assert %User{name: "default"} = SingleTenant.get_default_user()
    end

    test "get_default_plan/0" do
      assert {:ok, _plan} = SingleTenant.create_default_plan()
      assert %Plan{name: "Enterprise"} = SingleTenant.get_default_plan()
    end

    test "create_default_user/0, get_default_user/0 :inserts a default enterprise user if not present" do
      assert {:ok, _plan} = SingleTenant.create_default_plan()
      assert {:ok, user} = SingleTenant.create_default_user()
      assert user.email_preferred
      assert user.endpoints_beta
      # api key should be based on env var
      assert user.api_key == Application.get_env(:logflare, :api_key)
      plan = Billing.get_plan_by_user(user)
      assert plan.name == "Enterprise"
      assert {:error, :already_created} = SingleTenant.create_default_user()
    end

    test "single_tenant? returns true when in single tenant mode" do
      assert SingleTenant.single_tenant?()
    end

    test "Logflare.Application.startup_tasks/0 should insert plan and user" do
      Logflare.Application.startup_tasks()

      assert [_] = Billing.list_plans()
      assert 1 = Users.count_users()
    end
  end

  test "single_tenant? returns false when not in single tenant mode" do
    refute SingleTenant.single_tenant?()
  end

  describe "supabase_mode=true" do
    TestUtils.setup_single_tenant(seed_user: true, supabase_mode: true)

    test "create_supabase_sources/0, create_supabase_endpoints/0" do
      assert {:ok, [_ | _]} = SingleTenant.create_supabase_sources()
      assert {:error, :already_created} = SingleTenant.create_supabase_sources()

      # must have sources created first
      assert {:ok, [_ | _]} = SingleTenant.create_supabase_endpoints()
      assert {:error, :already_created} = SingleTenant.create_supabase_endpoints()
    end

    test "startup tasks inserts log sources/endpoints" do
      Logflare.Application.startup_tasks()
      user = SingleTenant.get_default_user()
      assert Sources.list_sources_by_user(user) |> length() > 0
      assert Endpoints.list_endpoints_by(user_id: user.id) |> length() > 0
    end
  end
end