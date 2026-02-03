defmodule Kubesee.SinkTest do
  use ExUnit.Case

  alias Kubesee.Sinks.Stdout

  describe "Kubesee.Sink behaviour" do
    test "module exists" do
      assert Code.ensure_loaded?(Kubesee.Sink)
    end

    test "Stdout implements the behaviour" do
      behaviours = Stdout.module_info(:attributes)
      assert {:behaviour, [Kubesee.Sink]} in behaviours
    end

    test "Stdout has all required callbacks" do
      exports = Stdout.module_info(:exports)
      assert Enum.any?(exports, &match?({:start_link, 1}, &1))
      assert Enum.any?(exports, &match?({:send, 2}, &1))
      assert Enum.any?(exports, &match?({:close, 1}, &1))
    end
  end
end
