defmodule PidroEngineTest do
  use ExUnit.Case
  doctest PidroEngine

  test "greets the world" do
    assert PidroEngine.hello() == :world
  end
end
