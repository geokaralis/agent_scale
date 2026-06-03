defmodule AgentScale.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentScale.Registry},
      {Registry, keys: :duplicate, name: AgentScale.PubSub},
      {AgentScale.Limiter, max: default_slots()},
      {DynamicSupervisor, name: AgentScale.RunSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: AgentScale.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_slots do
    Application.get_env(:agent_scale, :max_slots, System.schedulers_online() * 2)
  end
end
