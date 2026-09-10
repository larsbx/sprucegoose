defmodule SpruceGoose.Web.AdminPlug do
  @moduledoc """
  Operator dashboard behind Tailscale Serve's loopback proxy.

  The proxy-provided login is accepted only from a loopback peer and must
  match the configured administrator exactly. SpruceGoose still resolves the
  configured actor and applies its normal Ash read policies.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", remote_ip: remote_ip} = conn, opts) do
    loader = Keyword.get(opts, :dashboard_loader, &load_dashboard/1)

    with {:ok, actor_name} <- authenticate(conn, remote_ip, opts),
         {:ok, dashboard} <- loader.(actor_name) do
      conn
      |> secure_headers()
      |> put_resp_content_type("text/html")
      |> send_resp(200, render(dashboard))
    else
      {:error, :unauthorized} -> forbidden(conn)
      {:error, _reason} -> unavailable(conn)
      _ -> forbidden(conn)
    end
  end

  def call(
        %Plug.Conn{
          method: "POST",
          remote_ip: remote_ip,
          path_info: ["tasks", task_id, action]
        } = conn,
        opts
      ) do
    transitioner = Keyword.get(opts, :transitioner, &SpruceGoose.CLI.Executor.run/2)

    with {:ok, actor_name} <- authenticate(conn, remote_ip, opts),
         {:ok, target} <- transition_target(action),
         {:ok, _task} <- transitioner.({:transition_task, task_id, target, nil}, actor_name) do
      conn
      |> secure_headers()
      |> put_resp_header("location", "/admin")
      |> send_resp(303, "See Other")
    else
      :unknown_action -> conn |> secure_headers() |> send_resp(404, "Not Found") |> halt()
      {:error, :unauthorized} -> forbidden(conn)
      {:error, _reason} -> conn |> secure_headers() |> send_resp(409, "Action refused") |> halt()
      _ -> forbidden(conn)
    end
  end

  def call(conn, _opts), do: conn |> send_resp(404, "Not Found") |> halt()

  defp authenticate(conn, remote_ip, opts) do
    trusted_login = option(opts, :trusted_login, :admin_tailscale_login)
    actor_name = option(opts, :actor_name, :admin_actor)

    with true <- loopback?(remote_ip),
         [login] <- get_req_header(conn, "tailscale-user-login"),
         true <- configured?(trusted_login) and secure_equal(login, trusted_login),
         true <- configured?(actor_name) do
      {:ok, actor_name}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp transition_target("propose"), do: {:ok, :proposed}
  defp transition_target("queue"), do: {:ok, :queued}
  defp transition_target("ready"), do: {:ok, :ready}
  defp transition_target("start"), do: {:ok, :in_progress}
  defp transition_target("done"), do: {:ok, :completed}
  defp transition_target(_action), do: :unknown_action

  defp load_dashboard(actor_name) do
    SpruceGoose.CLI.Executor.run(
      {:list_tasks, %{sort: "priority", limit: 100}},
      actor_name
    )
  end

  defp option(opts, key, app_key) do
    Keyword.get(opts, key, Application.get_env(:spruce_goose, app_key))
  end

  defp configured?(value), do: is_binary(value) and value != ""

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false

  defp secure_equal(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal(_left, _right), do: false

  defp forbidden(conn), do: conn |> secure_headers() |> send_resp(403, "Forbidden") |> halt()

  defp unavailable(conn),
    do: conn |> secure_headers() |> send_resp(503, "Dashboard unavailable") |> halt()

  defp secure_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
  end

  defp render(%{tasks: tasks, total: total}) do
    rows = Enum.map_join(tasks, "", &task_row/1)
    active = Enum.count(tasks, &active?/1)
    waiting = Enum.count(tasks, &waiting?/1)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>SpruceGoose admin</title>
      <style>
        :root{color-scheme:light;--ink:#17211a;--muted:#667069;--line:#dfe4df;--panel:#fff;--canvas:#f5f7f5;--brand:#1f4d34;--brand-dark:#163925;--accent:#2f7d50}
        *{box-sizing:border-box}body{margin:0;font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--canvas);color:var(--ink)}
        a{color:inherit;text-decoration:none}.topbar{height:56px;display:flex;align-items:center;gap:12px;padding:0 22px;background:var(--brand-dark);color:#fff;border-bottom:1px solid #0d2918}
        .logo{display:grid;place-items:center;width:30px;height:30px;border-radius:7px;background:#d8f3df;color:var(--brand-dark);font-weight:900}.brand{font-size:16px;font-weight:700}.topbar-note{margin-left:auto;color:#c7d6cb;font-size:12px}
        .app-shell{display:grid;grid-template-columns:220px minmax(0,1fr);min-height:calc(100vh - 56px)}
        .sidebar{padding:22px 14px;background:#eef2ee;border-right:1px solid var(--line)}.nav-label{padding:0 10px 8px;color:#7b857e;font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}
        .nav-link{display:flex;align-items:center;gap:9px;padding:9px 10px;border-radius:6px;color:#39443c;font-weight:600}.nav-link.active{background:#dce8de;color:#173c27}.nav-icon{width:18px;color:#55705d;text-align:center}
        main{min-width:0;padding:30px 34px 48px}.content{max-width:1280px;margin:0 auto}.page-head{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin-bottom:20px}
        h1{margin:0;font-size:25px;letter-spacing:-.02em}.summary{margin:5px 0 0;color:var(--muted)}.eyebrow{margin:0 0 3px;color:var(--accent);font-size:11px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}
        .metrics{display:flex;gap:10px}.metric{min-width:92px;padding:9px 12px;background:var(--panel);border:1px solid var(--line);border-radius:7px}.metric strong{display:block;font-size:18px}.metric span{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
        .panel{overflow:hidden;background:var(--panel);border:1px solid var(--line);border-radius:8px;box-shadow:0 1px 2px rgb(20 40 25/.04)}.panel-head{display:flex;align-items:center;justify-content:space-between;padding:14px 16px;border-bottom:1px solid var(--line)}.panel-head h2{margin:0;font-size:15px}
        .task-list{width:100%;border-collapse:collapse}.task-list th,.task-list td{padding:11px 14px;text-align:left;border-bottom:1px solid #edf0ed;vertical-align:middle}.task-list th{background:#fafbfa;color:#667069;font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase}.task-list tr:last-child td{border-bottom:0}.task-list tbody tr:hover{background:#f8faf8}
        code{font:12px ui-monospace,SFMono-Regular,Consolas,monospace;color:#465149}.task-title{min-width:260px;font-weight:600}.project{color:var(--muted)}
        .priority{display:inline-grid;place-items:center;min-width:24px;height:24px;padding:0 6px;border:1px solid #ccd4ce;border-radius:5px;background:#f8faf8;font-weight:700}
        .state{display:inline-block;padding:3px 8px;border-radius:999px;background:#e9eeea;color:#4c5950;font-size:11px;font-weight:800;white-space:nowrap;text-transform:capitalize}.state--in-progress{background:#dcebea;color:#17615c}.state--waiting{background:#fff0ce;color:#755300}.state--completed{background:#dff0e3;color:#21603a}.state--ready{background:#e7e4f7;color:#51468c}.state--queued,.state--proposed{background:#e4ecf6;color:#355e83}
        form{margin:0}button{padding:6px 10px;border:1px solid #286b44;border-radius:6px;background:var(--accent);color:#fff;font:inherit;font-weight:700;cursor:pointer}button:hover{background:#266b44}button:focus-visible,a:focus-visible{outline:3px solid #8fc9a3;outline-offset:2px}
        @media(max-width:850px){.app-shell{grid-template-columns:1fr}.sidebar{display:none}main{padding:22px 14px}.page-head{align-items:flex-start;flex-direction:column}.metrics{width:100%}.metric{flex:1}.panel{overflow-x:auto}.task-list{min-width:880px}.topbar-note{display:none}}
      </style>
    </head>
    <body>
      <header class="topbar"><span class="logo" aria-hidden="true">S</span><span class="brand">SpruceGoose</span><span class="topbar-note">Governed operations</span></header>
      <div class="app-shell">
        <aside class="sidebar"><nav aria-label="Administration"><div class="nav-label">Administration</div><a class="nav-link active" href="/admin" aria-current="page"><span class="nav-icon" aria-hidden="true">▦</span>Operations</a></nav></aside>
        <main><div class="content">
          <div class="page-head"><div><p class="eyebrow">Operations</p><h1>SpruceGoose admin</h1><p class="summary">Tasks visible to the configured administrator.</p></div>
            <div class="metrics"><div class="metric"><strong>#{escape(total)}</strong><span>Visible</span></div><div class="metric"><strong>#{active}</strong><span>Active</span></div><div class="metric"><strong>#{waiting}</strong><span>Waiting</span></div></div>
          </div>
          <section class="panel" aria-labelledby="tasks-heading"><div class="panel-head"><h2 id="tasks-heading">Tasks</h2><span class="summary">Sorted by priority</span></div>
      <table class="task-list">
        <thead><tr><th>Priority</th><th>State</th><th>Task</th><th>Project</th><th>Title</th><th>Control</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
          </section>
        </div></main>
      </div>
    </body>
    </html>
    """
  end

  defp task_row(task) do
    """
    <tr><td><span class="priority">#{escape(task.priority || "-")}</span></td><td><span class="state #{state_class(task.state)}">#{state_label(task.state)}</span></td><td><code>#{escape(task.id)}</code></td><td class="project">#{escape(task.project || "-")}</td><td class="task-title">#{escape(task.title)}</td><td>#{task_control(task)}</td></tr>
    """
  end

  defp active?(%{state: state}), do: state in [:in_progress, "in_progress"]
  defp waiting?(%{state: state}), do: state in [:waiting, "waiting"]

  defp state_class(state) do
    case to_string(state) do
      value when value in ~w(in_progress waiting completed ready queued proposed) ->
        "state--" <> String.replace(value, "_", "-")

      _value ->
        "state--other"
    end
  end

  defp state_label(state), do: state |> to_string() |> String.replace("_", " ") |> escape()

  defp task_control(task) do
    case primary_action(task.state) do
      nil ->
        "-"

      {action, label} ->
        """
        <form method="post" action="/admin/tasks/#{escape(task.id)}/#{action}">
          <input type="hidden" name="_csrf_token" value="#{escape(Plug.CSRFProtection.get_csrf_token())}">
          <button type="submit">#{label}</button>
        </form>
        """
    end
  end

  defp primary_action(state) when state in [:inbox, "inbox"], do: {"propose", "Propose"}
  defp primary_action(state) when state in [:proposed, "proposed"], do: {"queue", "Queue"}
  defp primary_action(state) when state in [:queued, "queued"], do: {"ready", "Mark ready"}
  defp primary_action(state) when state in [:ready, "ready"], do: {"start", "Start"}

  defp primary_action(state) when state in [:in_progress, "in_progress"],
    do: {"done", "Complete"}

  defp primary_action(_state), do: nil

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
