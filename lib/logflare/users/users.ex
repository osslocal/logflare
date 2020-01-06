defmodule Logflare.Users do
  alias Logflare.{User, Repo, Sources, Users}
  alias Logflare.Repo
  alias Logflare.Sources
  @moduledoc false

  def get(user_id) do
    User
    |> Repo.get(user_id)
  end

  def get_by(keyword) do
    User
    |> Repo.get_by(keyword)
  end

  def get_by_and_preload(keyword) do
    User
    |> Repo.get_by(keyword)
    |> preload_defaults()
  end

  def preload_team_users(user) do
    user
    |> Repo.preload(:team_users)
  end

  def preload_defaults(user) do
    user
    |> Repo.preload(:sources)
  end

  def get_by_source(source_id) when is_atom(source_id) do
    %Logflare.Source{user_id: user_id} = Sources.get_by(token: source_id)
    Users.get_by_and_preload(id: user_id)
  end

  def insert_or_update_user(auth_params) do
    cond do
      user = Repo.get_by(User, provider_uid: auth_params.provider_uid) ->
        update_user_by_provider_id(user, auth_params)

      user = Repo.get_by(User, email: auth_params.email) ->
        update_user_by_email(user, auth_params)

      true ->
        api_key = :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> binary_part(0, 12)
        auth_params = Map.put(auth_params, :api_key, api_key)

        changeset = User.changeset(%User{}, auth_params)
        Repo.insert(changeset)
    end
  end

  defp update_user_by_email(user, auth_params) do
    updated_changeset = User.changeset(user, auth_params)

    case Repo.update(updated_changeset) do
      {:ok, user} ->
        {:ok_found_user, user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp update_user_by_provider_id(user, auth_params) do
    updated_changeset = User.changeset(user, auth_params)

    case Repo.update(updated_changeset) do
      {:ok, user} ->
        {:ok_found_user, user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
