defmodule PidroServer.Invites.DeferredMatcherTest do
  use ExUnit.Case, async: true

  alias PidroServer.Invites.DeferredMatcher

  @secret String.duplicate("s", 64)

  defp signature(overrides \\ %{}) do
    Map.merge(
      %{
        ip: "203.0.113.7",
        platform: "ios",
        os_major: "18",
        screen_class: "compact",
        locale: "en-US",
        timezone: "Europe/Madrid"
      },
      overrides
    )
  end

  defp start_matcher(context, overrides \\ []) do
    name = String.to_atom("deferred_matcher_#{context.test}")

    opts =
      Keyword.merge(
        [
          name: name,
          enabled: true,
          retention_ms: 100,
          max_candidates: 10,
          secret_key_base: @secret
        ],
        overrides
      )

    start_supervised!({DeferredMatcher, opts})
    name
  end

  test "a unique candidate is consumed once across multiple digest variants", context do
    matcher = start_matcher(context)
    actual = signature(%{platform: "android", os_major: "16"})
    reduced = signature(%{platform: "android", os_major: "10"})

    assert :created = DeferredMatcher.capture("ABCD2345", actual, matcher)
    assert :created = DeferredMatcher.capture("ABCD2345", reduced, matcher)
    assert {:ok, "ABCD2345"} = DeferredMatcher.consume([actual, reduced], matcher)
    assert :none = DeferredMatcher.consume([actual, reduced], matcher)
  end

  test "repeat capture does not extend the original deadline", context do
    matcher = start_matcher(context, retention_ms: 60)
    candidate = signature()

    assert :created = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    Process.sleep(40)
    assert :existing = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    Process.sleep(30)
    assert :none = DeferredMatcher.consume([candidate], matcher)
  end

  test "different live codes are ambiguous and the whole bucket is consumed", context do
    matcher = start_matcher(context)
    candidate = signature()

    assert :created = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    assert :created = DeferredMatcher.capture("WXYZ6789", candidate, matcher)
    assert :ambiguous = DeferredMatcher.consume([candidate], matcher)
    assert :none = DeferredMatcher.consume([candidate], matcher)
  end

  test "identical code captures deduplicate while capacity counts candidates", context do
    matcher = start_matcher(context, max_candidates: 1)
    first = signature()
    second = signature(%{ip: "203.0.113.8"})

    assert :created = DeferredMatcher.capture("ABCD2345", first, matcher)
    assert :existing = DeferredMatcher.capture("ABCD2345", first, matcher)
    assert :capacity = DeferredMatcher.capture("ABCD2345", second, matcher)
    assert {:ok, "ABCD2345"} = DeferredMatcher.consume([first], matcher)
  end

  test "disabled matcher neither stores nor resolves candidates", context do
    matcher = start_matcher(context, enabled: false)
    candidate = signature()

    assert :disabled = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    assert :none = DeferredMatcher.consume([candidate], matcher)
    assert %{buckets: %{}, candidate_count: 0} = :sys.get_state(matcher)
  end

  test "state contains only keyed digests and normalized invite codes", context do
    matcher = start_matcher(context)
    candidate = signature()

    assert :created = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    state_dump = matcher |> :sys.get_state() |> inspect(limit: :infinity)

    refute state_dump =~ candidate.ip
    refute state_dump =~ candidate.locale
    refute state_dump =~ candidate.timezone
    assert state_dump =~ "ABCD2345"
  end

  test "terminating the process removes every candidate", context do
    matcher = start_matcher(context)
    candidate = signature()

    assert :created = DeferredMatcher.capture("ABCD2345", candidate, matcher)
    pid = Process.whereis(matcher)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    refute Process.alive?(pid)
  end

  test "the application supervisor has exactly one named matcher owner" do
    children = Supervisor.which_children(PidroServer.Supervisor)

    assert [{DeferredMatcher, pid, :worker, [DeferredMatcher]}] =
             Enum.filter(children, fn {id, _pid, _type, _modules} -> id == DeferredMatcher end)

    assert pid == Process.whereis(DeferredMatcher)
  end

  test "the expiry timer physically removes a candidate", context do
    matcher = start_matcher(context, retention_ms: 20)
    assert :created = DeferredMatcher.capture("ABCD2345", signature(), matcher)

    Process.sleep(50)

    assert %{buckets: %{}, candidate_count: 0} = :sys.get_state(matcher)
  end
end
