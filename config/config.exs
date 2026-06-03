import Config

# Default number of concurrent inference slots
# config :agent_scale, :max_slots, 8

# Import environment specific config
import_config "#{config_env()}.exs"
