defmodule SpruceGoose.Web.AdminPlugTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Web.AdminPlug

  test "the router exposes the admin dashboard and keeps it closed by default" do
    conn =
      :get
      |> Plug.Test.conn("/admin")
      |> Plug.Test.init_test_session(%{})
      |> SpruceGoose.Web.Router.call(SpruceGoose.Web.Router.init([]))

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "refuses requests without the trusted Tailscale identity" do
    conn =
      :get
      |> Plug.Test.conn("/admin")
      |> AdminPlug.call(
        AdminPlug.init(
          trusted_login: "lars@example.test",
          actor_name: "lars",
          dashboard_loader: fn _actor -> flunk("unauthorized request reached the loader") end
        )
      )

    assert conn.halted
    assert conn.status == 403
    assert conn.resp_body == "Forbidden"
  end

  test "renders authorized task data and escapes stored text" do
    loader = fn "lars" ->
      {:ok,
       %{
         total: 1,
         tasks: [
           %{
             id: "tsk-20260909T165852Z-b80d7dc7",
             title: "Review <script>alert('no')</script>",
             state: "in_progress",
             priority: 1,
             project: "sprucegoose-dogfood"
           }
         ]
       }}
    end

    conn =
      :get
      |> Plug.Test.conn("/admin")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("tailscale-user-login", "lars@example.test")
      |> AdminPlug.call(
        AdminPlug.init(
          trusted_login: "lars@example.test",
          actor_name: "lars",
          dashboard_loader: loader
        )
      )

    assert conn.status == 200
    assert conn.resp_body =~ "SpruceGoose admin"
    assert conn.resp_body =~ "tsk-20260909T165852Z-b80d7dc7"
    assert conn.resp_body =~ "Review &lt;script&gt;alert(&#39;no&#39;)&lt;/script&gt;"

    assert conn.resp_body =~
             ~s(action="/admin/tasks/tsk-20260909T165852Z-b80d7dc7/done")

    assert conn.resp_body =~ ~s(name="_csrf_token")
    refute conn.resp_body =~ "<script>"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(conn, "content-security-policy") != []
  end

  test "runs an allowlisted task transition under the configured actor" do
    parent = self()

    conn =
      :post
      |> Plug.Test.conn("/tasks/tsk-20260909T165852Z-b80d7dc7/queue")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("tailscale-user-login", "lars@example.test")
      |> AdminPlug.call(
        AdminPlug.init(
          trusted_login: "lars@example.test",
          actor_name: "lars",
          transitioner: fn command, actor ->
            send(parent, {:transition, command, actor})
            {:ok, %{state: :queued}}
          end
        )
      )

    assert conn.status == 303
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin"]

    assert_receive {:transition,
                    {:transition_task, "tsk-20260909T165852Z-b80d7dc7", :queued, nil}, "lars"}
  end

  test "refuses an action that is not allowlisted" do
    conn =
      :post
      |> Plug.Test.conn("/tasks/tsk-20260909T165852Z-b80d7dc7/delete")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("tailscale-user-login", "lars@example.test")
      |> AdminPlug.call(
        AdminPlug.init(
          trusted_login: "lars@example.test",
          actor_name: "lars",
          transitioner: fn _command, _actor -> flunk("unknown action reached executor") end
        )
      )

    assert conn.status == 404
  end

  test "refuses a trusted header arriving from a non-loopback peer" do
    conn =
      :get
      |> Plug.Test.conn("/admin")
      |> Map.put(:remote_ip, {100, 64, 0, 10})
      |> Plug.Conn.put_req_header("tailscale-user-login", "lars@example.test")
      |> AdminPlug.call(
        AdminPlug.init(
          trusted_login: "lars@example.test",
          actor_name: "lars",
          dashboard_loader: fn _actor -> flunk("untrusted peer reached the loader") end
        )
      )

    assert conn.halted
    assert conn.status == 403
  end
end
