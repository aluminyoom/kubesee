defmodule Kubesee.Sinks.FactoryTest do
  use ExUnit.Case, async: true

  alias Kubesee.Config.Receiver
  alias Kubesee.Sinks.Factory

  describe "create/1" do
    test "creates stdout sink from receiver config" do
      receiver = %Receiver{
        name: "test-stdout",
        sink_type: :stdout,
        sink_config: %{}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "creates stdout sink with deDot config" do
      receiver = %Receiver{
        name: "test-stdout-dedot",
        sink_type: :stdout,
        sink_config: %{"deDot" => true}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "creates file sink from receiver config" do
      path = "/tmp/kubesee-factory-test-#{:rand.uniform(10000)}.log"

      receiver = %Receiver{
        name: "test-file",
        sink_type: :file,
        sink_config: %{"path" => path}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
      File.rm(path)
    end

    test "creates webhook sink from receiver config" do
      receiver = %Receiver{
        name: "test-webhook",
        sink_type: :webhook,
        sink_config: %{"endpoint" => "http://example.com/events"}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "creates pipe sink from receiver config" do
      path = "/tmp/kubesee-pipe-test-#{:rand.uniform(10000)}"

      receiver = %Receiver{
        name: "test-pipe",
        sink_type: :pipe,
        sink_config: %{"path" => path}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
      File.rm(path)
    end

    test "creates in_memory sink from receiver config" do
      receiver = %Receiver{
        name: "test-inmemory",
        sink_type: :in_memory,
        sink_config: %{"ref" => "test-ref"}
      }

      assert {:ok, pid} = Factory.create(receiver)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "returns error for unknown sink type" do
      receiver = %Receiver{
        name: "test-unknown",
        sink_type: :unknown_sink_type,
        sink_config: %{}
      }

      assert {:error, {:unsupported_sink, :unknown_sink_type}} = Factory.create(receiver)
    end

    test "returns error when receiver has nil sink_type" do
      receiver = %Receiver{
        name: "test-nil",
        sink_type: nil,
        sink_config: %{}
      }

      assert {:error, {:unsupported_sink, nil}} = Factory.create(receiver)
    end
  end
end
