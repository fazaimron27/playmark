defmodule Playmark.Player.FfplayTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Ffplay

  @opts %{title: "Some Video Title", author: "Some Channel"}

  describe "play_args/2" do
    test "plays fullscreen, exits at end, sets the window title" do
      args = Ffplay.play_args("https://example.com/muxed", @opts)

      assert args == [
               "-fs",
               "-autoexit",
               "-window_title",
               "Some Video Title",
               "https://example.com/muxed"
             ]
    end

    test "the url is last and present" do
      args = Ffplay.play_args("https://example.com/muxed", @opts)

      assert List.last(args) == "https://example.com/muxed"
    end

    test "ignores author (ffplay has no artist concept)" do
      args = Ffplay.play_args("https://example.com/muxed", @opts)

      refute Enum.any?(args, &String.contains?(&1, "Some Channel"))
    end

    test "omits the window title flag when no title is known" do
      args = Ffplay.play_args("https://example.com/muxed", %{title: nil})

      refute "-window_title" in args
    end

    test "omits the window title flag when the title is blank" do
      args = Ffplay.play_args("https://example.com/muxed", %{title: "   "})

      refute "-window_title" in args
    end

    test "omits the window title flag when the title key is absent" do
      args = Ffplay.play_args("https://example.com/muxed", %{})

      refute "-window_title" in args
    end
  end

  test "executable/0 is ffplay" do
    assert Ffplay.executable() == "ffplay"
  end
end
