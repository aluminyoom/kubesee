defmodule Kubesee.RegistryTest do
  use ExUnit.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Kubesee.Config.Receiver
  alias Kubesee.Event
  alias Kubesee.Registry

  defp receiver(name) do
    %Receiver{name: name, sink_type: :stdout, sink_config: %{}}
  end

  defp start_registry(receivers) do
    start_registry(receivers, [])
  end

  defp start_registry(receivers, opts) do
    {:ok, pid} = Registry.start_link(receivers, opts)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    pid
  end

  defp event(name) do
    %Event{name: name, reason: "Created", message: "Test message"}
  end

  defp capture_sink_output(pid, fun) do
    capture_io(fn ->
      state = :sys.get_state(pid)

      Enum.each(state.sinks, fn {_name, sink_pid} ->
        Process.group_leader(sink_pid, Process.group_leader())
      end)

      fun.()
    end)
  end

  describe "start_link/1" do
    test "registers receivers and initializes state" do
      pid = start_registry([receiver("stdout")])

      state = :sys.get_state(pid)

      assert is_pid(state.task_sup)
      assert Process.alive?(state.task_sup)
      assert state.max_queue_size == 1000
      assert %{"stdout" => sink_pid} = state.sinks
      assert Process.alive?(sink_pid)
      assert :queue.is_empty(state.queues["stdout"])
    end
  end

  describe "register/2" do
    test "starts sink process and queue" do
      pid = start_registry([])

      assert {:ok, sink_pid} = Registry.register(pid, receiver("stdout"))
      assert Process.alive?(sink_pid)

      state = :sys.get_state(pid)

      assert state.sinks["stdout"] == sink_pid
      assert :queue.is_empty(state.queues["stdout"])
    end
  end

  describe "send/2" do
    test "dispatches via the default registry name" do
      pid = start_registry([receiver("stdout")], name: Kubesee.Registry)
      event = event("named-send")

      output =
        capture_sink_output(pid, fn ->
          assert :ok = Registry.send("stdout", event)
          assert :ok = Registry.drain(pid, "stdout", 5_000)
        end)

      assert output =~ "named-send"
    end
  end

  describe "send/3 and drain" do
    test "queues events and drains to empty" do
      pid = start_registry([receiver("stdout")])

      output =
        capture_sink_output(pid, fn ->
          assert :ok = Registry.send(pid, "stdout", event("one"))
          assert :ok = Registry.send(pid, "stdout", event("two"))
          assert :ok = Registry.drain(pid, "stdout", 5_000)
        end)

      assert output =~ "one"
      assert output =~ "two"

      state = :sys.get_state(pid)
      assert :queue.is_empty(state.queues["stdout"])
    end
  end

  describe "drain_all/1" do
    test "drains all registered sinks" do
      pid = start_registry([receiver("stdout"), receiver("audit")])

      output =
        capture_sink_output(pid, fn ->
          assert :ok = Registry.send(pid, "stdout", event("primary"))
          assert :ok = Registry.send(pid, "audit", event("secondary"))
          assert :ok = Registry.drain_all(pid)
        end)

      assert output =~ "primary"
      assert output =~ "secondary"

      state = :sys.get_state(pid)
      assert :queue.is_empty(state.queues["stdout"])
      assert :queue.is_empty(state.queues["audit"])
    end
  end

  describe "close/2" do
    test "closes a single sink and clears state" do
      pid = start_registry([receiver("stdout")])
      sink_pid = :sys.get_state(pid).sinks["stdout"]

      assert :ok = Registry.close(pid, "stdout")
      refute Process.alive?(sink_pid)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.sinks, "stdout")
      refute Map.has_key?(state.queues, "stdout")
    end
  end

  describe "close_all/1" do
    test "closes all sinks and clears state" do
      pid = start_registry([receiver("stdout"), receiver("audit")])
      sink_pids = Map.values(:sys.get_state(pid).sinks)

      assert :ok = Registry.close_all(pid)

      Enum.each(sink_pids, fn sink_pid ->
        refute Process.alive?(sink_pid)
      end)

      state = :sys.get_state(pid)
      assert state.sinks == %{}
      assert state.queues == %{}
    end
  end

  describe "queue overflow" do
    test "drops newest event and logs warning" do
      pid = start_registry([receiver("stdout")], max_queue_size: 1)

      log =
        capture_log(fn ->
          output =
            capture_sink_output(pid, fn ->
              assert :ok = Registry.send(pid, "stdout", event("first"))
              assert :ok = Registry.send(pid, "stdout", event("second"))
              assert :ok = Registry.drain(pid, "stdout", 5_000)
            end)

          send(self(), {:captured_output, output})
        end)

      assert_receive {:captured_output, output}

      assert log =~ "queue full"
      assert output =~ "first"
      refute output =~ "second"
    end
  end

  describe "concurrent sends" do
    test "handles concurrent dispatches" do
      pid = start_registry([receiver("stdout")])

      events =
        for idx <- 1..25 do
          event("concurrent-#{idx}")
        end

      output =
        capture_sink_output(pid, fn ->
          results =
            Enum.to_list(
              Task.async_stream(events, fn ev ->
                Registry.send(pid, "stdout", ev)
              end,
                max_concurrency: 8,
                timeout: 5_000
              )
            )

          assert Enum.all?(results, &match?({:ok, :ok}, &1))

          assert :ok = Registry.drain(pid, "stdout", 5_000)
        end)

      assert output =~ "concurrent-1"

      state = :sys.get_state(pid)
      assert :queue.is_empty(state.queues["stdout"])
    end
  end
end
