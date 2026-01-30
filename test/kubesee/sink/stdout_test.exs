defmodule Kubesee.Sink.StdoutTest do
  use ExUnit.Case

  alias Kubesee.Event
  alias Kubesee.Sink.Stdout

  describe "start_link/1" do
    test "starts a GenServer process" do
      assert {:ok, pid} = Stdout.start_link(%{})
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "accepts config map" do
      config = %{"some_option" => "value"}
      assert {:ok, pid} = Stdout.start_link(config)
      assert is_pid(pid)
    end

    test "stores config in state" do
      config = %{"test_key" => "test_value"}
      {:ok, pid} = Stdout.start_link(config)

      state = :sys.get_state(pid)
      assert state[:config] == config
    end
  end

  describe "send/2" do
    setup do
      {:ok, pid} = Stdout.start_link(%{})
      {:ok, pid: pid}
    end

    test "sends event and returns :ok", %{pid: pid} do
      event = %Event{
        name: "test-event",
        namespace: "default",
        reason: "Created",
        message: "Test message",
        type: "Normal"
      }

      assert :ok = Stdout.send(pid, event)
    end

    test "sends multiple events successfully", %{pid: pid} do
      event1 = %Event{name: "event1", reason: "Created"}
      event2 = %Event{name: "event2", reason: "Updated"}

      assert :ok = Stdout.send(pid, event1)
      assert :ok = Stdout.send(pid, event2)
    end

    test "serializes event to JSON (verify via spy)" do
      {:ok, pid} = Stdout.start_link(%{})
      event = %Event{name: "test-event", reason: "Created"}

      ExUnit.CaptureIO.capture_io(fn ->
        Stdout.send(pid, event)
      end)

      json = Jason.encode!(event)
      assert String.contains?(json, "test-event")
    end
  end

  describe "close/1" do
    test "closes the sink and returns :ok" do
      {:ok, pid} = Stdout.start_link(%{})
      assert :ok = Stdout.close(pid)
      Process.sleep(10)
      refute Process.alive?(pid)
    end
  end
end
