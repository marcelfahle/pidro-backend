defmodule PidroServer.RateLimit do
  @moduledoc """
  Hammer rate limiter backed by a node-local ETS table.

  Started in `PidroServer.Application` before the endpoint with
  `{PidroServer.RateLimit, clean_period: :timer.minutes(1)}`. Counters live in
  the ETS table named after this module, so limits are per node and reset on
  restart. The fixed-window algorithm admits up to twice the limit across a
  window boundary, which is acceptable for the policies applied by
  `PidroServerWeb.Plugs.RateLimit`.

      PidroServer.RateLimit.hit("login:ip:203.0.113.9", 60_000, 10)
      #=> {:allow, 1} | {:deny, ms_until_window_reset}
  """

  use Hammer, backend: :ets
end
