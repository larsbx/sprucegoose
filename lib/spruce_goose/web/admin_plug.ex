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

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>SpruceGoose admin</title>
      <style>
        body{font:16px system-ui,sans-serif;margin:2rem;background:#f4f5f2;color:#182018}
        main{max-width:1100px;margin:auto} table{width:100%;border-collapse:collapse;background:white}
        th,td{padding:.7rem;text-align:left;border-bottom:1px solid #d9ddd7} th{background:#263d2b;color:white}
        .state{font-weight:700} code{font-size:.85em} .summary{color:#526054}
      </style>
    </head>
    <body><main>
      <h1>SpruceGoose admin</h1>
      <p class="summary">#{escape(total)} tasks visible to this administrator.</p>
      <table>
        <thead><tr><th>Priority</th><th>State</th><th>Task</th><th>Project</th><th>Title</th><th>Control</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </main></body>
    </html>
    """
  end

  defp task_row(task) do
    """
    <tr><td>#{escape(task.priority || "-")}</td><td class="state">#{escape(task.state)}</td><td><code>#{escape(task.id)}</code></td><td>#{escape(task.project || "-")}</td><td>#{escape(task.title)}</td><td>#{task_control(task)}</td></tr>
    """
  end

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
