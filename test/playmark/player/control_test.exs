defmodule Playmark.Player.ControlTest do
  use ExUnit.Case, async: true

  alias Playmark.Player.Control

  describe "parse_mpv_line/1" do
    test "parses observed timing and seekability properties" do
      assert Control.parse_mpv_line(
               ~s({"event":"property-change","name":"time-pos","data":12.345})
             ) ==
               {:position, 12_345}

      assert Control.parse_mpv_line(~s({"event":"property-change","name":"duration","data":300})) ==
               {:duration, 300_000}

      assert Control.parse_mpv_line(~s({"event":"property-change","name":"seekable","data":true})) ==
               {:seekable, true}
    end

    test "parses EOF and ignores unrelated or malformed messages" do
      assert Control.parse_mpv_line(~s({"event":"end-file","reason":"eof"})) ==
               {:end_file, "eof"}

      assert Control.parse_mpv_line(~s({"event":"idle"})) == :ignore
      assert Control.parse_mpv_line("not json") == :ignore
    end
  end

  describe "parse_vlc_value/1" do
    test "parses plain and prompt-prefixed non-negative integer responses" do
      assert Control.parse_vlc_value("123\n") == {:ok, 123}
      assert Control.parse_vlc_value("> 456\n") == {:ok, 456}
    end

    test "ignores prompts, errors, and negative values" do
      assert Control.parse_vlc_value("> ") == :ignore
      assert Control.parse_vlc_value("status change: stop") == :ignore
      assert Control.parse_vlc_value("-1") == :ignore
    end
  end
end
