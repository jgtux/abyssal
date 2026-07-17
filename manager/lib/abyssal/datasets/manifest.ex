defmodule Abyssal.Datasets.Manifest do
  @moduledoc """
  The manifest published alongside every `.dwarfs` archive under
  ReleaseStore. This is deliberately small for the skeleton milestone --
  just enough to describe what got published and verify it later. Fields
  like compression profile, retention policy, etc. are future additions
  once those concepts actually exist (see README.md's Compression
  Profiles / Dynamic Compression Behavior sections).
  """

  @enforce_keys [:name, :version, :created_at, :archive_path, :archive_sha256, :entries]
  defstruct [
    :name,
    :version,
    :created_at,
    :archive_path,
    :archive_sha256,
    entries: [],
    encrypted: false,
    cipher: nil,
    nonce: nil
  ]

  @type entry :: %{path: String.t(), size: non_neg_integer()}
  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          created_at: DateTime.t(),
          archive_path: String.t(),
          archive_sha256: String.t(),
          entries: [entry()],
          encrypted: boolean(),
          # "aes-256-gcm" when encrypted, else nil.
          cipher: String.t() | nil,
          # Hex-encoded 12-byte AES-GCM nonce, for operator visibility only --
          # the engine always reads the real nonce back out of the archive
          # file itself (see engine/src/crypto.rs), never from here. The key
          # itself is never a manifest field: no persistent keystore.
          nonce: String.t() | nil
        }

  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Jason.encode!(pretty: true)
  end

  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) do
    with {:ok, decoded} <- Jason.decode(json, keys: :atoms),
         {:ok, created_at, _} <- DateTime.from_iso8601(decoded.created_at) do
      {:ok,
       %__MODULE__{
         name: decoded.name,
         version: decoded.version,
         created_at: created_at,
         archive_path: decoded.archive_path,
         archive_sha256: decoded.archive_sha256,
         entries: decoded.entries || [],
         # Map.get with defaults: manifests written before this feature
         # existed have none of these keys and must keep loading.
         encrypted: Map.get(decoded, :encrypted, false),
         cipher: Map.get(decoded, :cipher),
         nonce: Map.get(decoded, :nonce)
       }}
    end
  end
end
