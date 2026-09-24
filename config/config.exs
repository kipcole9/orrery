# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :orrery,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :orrery, OrreryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OrreryWeb.ErrorHTML, json: OrreryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Orrery.PubSub,
  live_view: [signing_salt: "J0soR+Qo"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  orrery: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  orrery: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use the JSON module from the Elixir standard library in Phoenix
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# The store collects on the hour from 05:00 to 20:00 local time and persists
# the report under :data_dir. Both can be overridden at runtime; see
# config/runtime.exs.
config :orrery, Orrery.Store,
  schedule: {:hourly, 5..20},
  collect_on_start: true
