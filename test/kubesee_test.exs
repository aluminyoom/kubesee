defmodule KubeseeTest do
  use ExUnit.Case

  test "version returns a string" do
    assert is_binary(Kubesee.version())
  end
end
