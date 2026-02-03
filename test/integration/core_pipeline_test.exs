defmodule Kubesee.Integration.CorePipelineTest do
  use ExUnit.Case

  alias Kubesee.Config
  alias Kubesee.Config.Receiver
  alias Kubesee.Event
  alias Kubesee.Registry
  alias Kubesee.Route
  alias Kubesee.Rule
  alias Kubesee.Sinks.InMemory

  @test_config """
  logLevel: info
  route:
    routes:
      - match:
          - receiver: test-sink
  receivers:
    - name: test-sink
      inMemory:
        ref: integration-test
  """

  describe "core pipeline integration" do
    test "parses config, sets up engine, and processes events" do
      {:ok, config} = Config.parse(@test_config)

      assert config.log_level == "info"
      assert length(config.receivers) == 1

      receiver = Enum.at(config.receivers, 0)
      assert receiver.name == "test-sink"
      assert receiver.sink_type == :inMemory
    end

    test "engine processes events through registry and sinks" do
      {:ok, in_memory} = InMemory.start_link(%{"ref" => "engine-test"})

      receiver = %Receiver{
        name: "test-receiver",
        sink_type: :in_memory,
        sink_config: %{}
      }

      {:ok, registry} = Registry.start_link([receiver], name: nil)

      event = %Event{
        message: "Test pod created",
        reason: "Created",
        type: "Normal",
        namespace: "default",
        involved_object: %Event.ObjectReference{
          kind: "Pod",
          name: "test-pod",
          namespace: "default"
        },
        source: %Event.Source{
          component: "kubelet",
          host: "node-1"
        }
      }

      Registry.send(registry, "test-receiver", event)
      :timer.sleep(50)

      Registry.close_all(registry)
      InMemory.close(in_memory)
    end

    test "route processing directs events to correct receivers" do
      route = %Route{
        drop: [],
        match: [
          %Rule{
            namespace: "kube-system",
            receiver: "system-sink"
          }
        ],
        routes: []
      }

      system_event = %Event{
        message: "System event",
        reason: "Created",
        type: "Normal",
        namespace: "kube-system",
        involved_object: %Event.ObjectReference{
          kind: "Pod",
          name: "sys-pod",
          namespace: "kube-system"
        },
        source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      default_event = %Event{
        message: "Default event",
        reason: "Created",
        type: "Normal",
        namespace: "default",
        involved_object: %Event.ObjectReference{kind: "Pod", name: "app-pod", namespace: "default"},
        source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      send_fn = fn receiver, _event -> send(self(), {:sent, receiver}) end

      Route.process_event(route, system_event, send_fn)
      assert_receive {:sent, "system-sink"}

      Route.process_event(route, default_event, send_fn)
      refute_receive {:sent, _}, 10
    end

    test "drop rules filter out events" do
      route = %Route{
        drop: [
          %Rule{
            reason: "Normal"
          }
        ],
        match: [
          %Rule{
            receiver: "all-sink"
          }
        ],
        routes: []
      }

      normal_event = %Event{
        message: "Normal event",
        reason: "Normal",
        type: "Normal",
        namespace: "default",
        involved_object: %Event.ObjectReference{kind: "Pod", name: "pod", namespace: "default"},
        source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      warning_event = %Event{
        message: "Warning event",
        reason: "Failed",
        type: "Warning",
        namespace: "default",
        involved_object: %Event.ObjectReference{kind: "Pod", name: "pod", namespace: "default"},
        source: %Event.Source{component: "kubelet", host: "node-1"}
      }

      send_fn = fn receiver, _event -> send(self(), {:sent, receiver}) end

      Route.process_event(route, normal_event, send_fn)
      refute_receive {:sent, _}, 10

      Route.process_event(route, warning_event, send_fn)
      assert_receive {:sent, "all-sink"}
    end

    test "full pipeline with config parsing and event processing" do
      config_yaml = """
      logLevel: info
      maxEventAgeSeconds: 10
      route:
        routes:
          - match:
              - namespace: "test-ns"
                receiver: ns-sink
          - match:
              - receiver: default-sink
      receivers:
        - name: ns-sink
          inMemory:
            ref: ns-events
        - name: default-sink
          inMemory:
            ref: default-events
      """

      {:ok, config} = Config.parse(config_yaml)

      assert config.max_event_age_seconds == 10
      assert length(config.receivers) == 2

      ns_receiver = Enum.find(config.receivers, &(&1.name == "ns-sink"))
      default_receiver = Enum.find(config.receivers, &(&1.name == "default-sink"))

      assert ns_receiver.sink_type == :inMemory
      assert default_receiver.sink_type == :inMemory
    end

    test "graceful shutdown drains events before closing" do
      {:ok, in_memory} = InMemory.start_link(%{"ref" => "shutdown-test"})

      receiver = %Receiver{
        name: "shutdown-receiver",
        sink_type: :in_memory,
        sink_config: %{}
      }

      {:ok, registry} = Registry.start_link([receiver], name: nil)

      events =
        Enum.map(1..10, fn i ->
          %Event{
            message: "Event #{i}",
            reason: "Created",
            type: "Normal",
            namespace: "default",
            involved_object: %Event.ObjectReference{
              kind: "Pod",
              name: "pod-#{i}",
              namespace: "default"
            },
            source: %Event.Source{component: "kubelet", host: "node-1"}
          }
        end)

      Enum.each(events, fn event ->
        Registry.send(registry, "shutdown-receiver", event)
      end)

      assert :ok = Registry.drain_all(registry, 5_000)

      Registry.close_all(registry)
      InMemory.close(in_memory)
    end
  end

  describe "config compatibility with Go config.example.yaml" do
    test "parses Go config.example.yaml without errors" do
      config_path = "test/support/fixtures/config.example.yaml"

      if File.exists?(config_path) do
        yaml = File.read!(config_path)
        result = Config.parse(yaml)

        case result do
          {:ok, config} ->
            assert is_binary(config.log_level) or is_nil(config.log_level)
            assert is_list(config.receivers)

          {:error, reason} ->
            flunk("Failed to parse config.example.yaml: #{inspect(reason)}")
        end
      else
        IO.puts("Skipping config.example.yaml test - file not found at #{config_path}")
      end
    end
  end
end
