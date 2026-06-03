import Config

# Test-specific configuration
config :logger, level: :warning

# Use fewer slots in tests for faster execution
config :agent_scale, :max_slots, 4
