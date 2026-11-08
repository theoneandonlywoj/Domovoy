# Log tests of crash paths that leak on Core v0.3.4 wait for a Core fix; see LEAK.md.
ExUnit.configure(exclude: [:pending_core_crash_redaction])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Domovoy.Repo, :manual)
