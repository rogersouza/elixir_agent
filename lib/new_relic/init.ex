defmodule NewRelic.Init do
  @moduledoc false

  def run() do
    verify_erlang_otp_version()
    init_config()
    init_features()
  end

  @erlang_version_requirement ">= 21.2.0"
  def verify_erlang_otp_version() do
    cond do
      Code.ensure_loaded?(:persistent_term) -> :ok
      Version.match?(System.otp_release() <> ".0.0", @erlang_version_requirement) -> :ok
      true -> raise "Erlang/OTP 21.2 required to run the New Relic agent"
    end
  end

  def init_config() do
    host = determine_config(:host)
    license_key = determine_config(:license_key)
    {collector_host, region_prefix} = determine_collector_host(host, license_key)
    telemetry_hosts = determine_telemetry_hosts(host, region_prefix)

    NewRelic.Config.put(%{
      log: determine_config(:log),
      host: host,
      port: determine_config(:port, 443) |> parse_port,
      scheme: determine_config(:scheme, "https"),
      app_name: determine_config(:app_name) |> parse_app_names,
      license_key: license_key,
      harvest_enabled: determine_config(:harvest_enabled, true),
      collector_host: collector_host,
      region_prefix: region_prefix,
      automatic_attributes: determine_automatic_attributes(),
      labels: determine_config(:labels) |> parse_labels(),
      telemetry_hosts: telemetry_hosts
    })
  end

  def init_features() do
    NewRelic.Config.put(:features, %{
      error_collector:
        determine_feature(
          "NEW_RELIC_ERROR_COLLECTOR_ENABLED",
          :error_collector_enabled
        ),
      db_query_collection:
        determine_feature(
          "NEW_RELIC_SQL_COLLECTION_ENABLED",
          :sql_collection_enabled,
          false
        ) ||
          determine_feature(
            "NEW_RELIC_DB_QUERY_COLLECTION_ENABLED",
            :db_query_collection_enabled
          ),
      ecto_instrumentation:
        determine_feature(
          "NEW_RELIC_ECTO_INSTRUMENTATION_ENABLED",
          :ecto_instrumentation_enabled
        ),
      redix_instrumentation:
        determine_feature(
          "NEW_RELIC_REDIX_INSTRUMENTATION_ENABLED",
          :redix_instrumentation_enabled
        ),
      function_argument_collection:
        determine_feature(
          "NEW_RELIC_FUNCTION_ARGUMENT_COLLECTION_ENABLED",
          :function_argument_collection_enabled
        ),
      request_queuing_metrics:
        determine_feature(
          "NEW_RELIC_REQUEST_QUEUING_METRICS_ENABLED",
          :request_queuing_metrics_enabled
        )
    })
  end

  defp determine_config(key, default) do
    determine_config(key) || default
  end

  defp determine_config(key) when is_atom(key) do
    env = key |> to_string() |> String.upcase()

    System.get_env("NEW_RELIC_#{env}") ||
      Application.get_env(:new_relic_agent, key)
  end

  defp determine_feature(env, config, default \\ true) do
    case System.get_env(env) do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:new_relic_agent, config, default)
    end
  end

  @env_matcher ~r/^(?<env>.+)-collector/
  def determine_telemetry_hosts(host, region) do
    env = host && Regex.named_captures(@env_matcher, host)["env"]
    env = env && env <> "-"
    region = region && region <> "."

    %{
      log: "https://#{env}log-api.#{region}newrelic.com/log/v1"
    }
  end

  def determine_collector_host(host, license_key) do
    cond do
      manual_config_host = host ->
        {manual_config_host, nil}

      region_prefix = determine_region(license_key) ->
        {"collector.#{region_prefix}.nr-data.net", region_prefix}

      true ->
        {"collector.newrelic.com", nil}
    end
  end

  def determine_automatic_attributes() do
    Application.get_env(:new_relic_agent, :automatic_attributes, [])
    |> Enum.into(%{}, fn
      {name, {:system, env_var}} -> {name, System.get_env(env_var)}
      {name, {m, f, a}} -> {name, apply(m, f, a)}
      {name, value} -> {name, value}
    end)
  end

  @region_matcher ~r/^(?<prefix>.+?)x/

  def determine_region(nil), do: false

  def determine_region(key) do
    case Regex.named_captures(@region_matcher, key) do
      %{"prefix" => prefix} -> String.trim_trailing(prefix, "x")
      _ -> false
    end
  end

  def parse_port(port) when is_integer(port), do: port
  def parse_port(port) when is_binary(port), do: String.to_integer(port)

  def parse_app_names(nil), do: nil

  def parse_app_names(name_string) do
    name_string
    |> String.split(";")
    |> Enum.map(&String.trim/1)
  end

  def parse_labels(nil), do: []

  @label_splitter ~r/;|:/
  def parse_labels(label_string) do
    label_string
    |> String.split(@label_splitter, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.chunk_every(2, 2, :discard)
  end
end
