defmodule Playmark.CacheTest do
  # async: false — a single named cache process/table is shared process-wide, so
  # parallel modules would step on each other's entries.
  use ExUnit.Case, async: false

  alias Playmark.Cache

  setup do
    Cache.clear()
    :ok
  end

  test "get/1 returns :miss for an unknown key" do
    assert Cache.get({:title, "nope"}) == :miss
  end

  test "put/2 then get/1 returns the stored value" do
    Cache.put({:title, "abc"}, "Some Title")
    # put/2 is a cast; flush it before reading.
    Cache.sync()
    assert Cache.get({:title, "abc"}) == {:ok, "Some Title"}
  end

  test "keys are namespaced independently" do
    Cache.put({:title, "x"}, "T")
    Cache.put({:other, "x"}, "O")
    Cache.sync()

    assert Cache.get({:title, "x"}) == {:ok, "T"}
    assert Cache.get({:other, "x"}) == {:ok, "O"}
  end

  test "clear/0 empties the cache" do
    Cache.put({:title, "abc"}, "Some Title")
    Cache.clear()
    assert Cache.get({:title, "abc"}) == :miss
  end
end
