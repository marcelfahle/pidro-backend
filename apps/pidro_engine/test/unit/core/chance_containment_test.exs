defmodule Pidro.Core.ChanceContainmentTest do
  @moduledoc """
  The guard that keeps process randomness out of the game domain.

  Every random draw the engine makes must come from the explicit chance stream
  carried in `%GameState{}`, which means `Pidro.Core.Chance` is the only module
  under `lib/pidro/core/`, `lib/pidro/game/` and `lib/pidro/finnish/` allowed to
  reach `:rand`. Behaviour tests can show that today's code is deterministic;
  only a scan of the sources can say that *no* path back to the process
  dictionary exists. That is why this one test reads code instead of running it.

  It reads the code as an AST rather than as text. `types.ex` has a
  `@type chance :: :rand.export_state()`, and several moduledocs name `:rand`
  when they explain the rule — a text scan would have to carve out exceptions
  for all of them by line number, and the exceptions would rot. Pruning
  type-expression attributes and ignoring string literals excludes those by
  construction, and leaves exactly the call sites.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)

  @domain_directories ["lib/pidro/core", "lib/pidro/game", "lib/pidro/finnish"]

  @chance_source "lib/pidro/core/chance.ex"

  # Attribute bodies that are type expressions rather than code. A reference to
  # `:rand.export_state()` inside one names a type; it draws nothing.
  @type_attributes [:type, :typep, :opaque, :spec, :callback, :macrocallback]

  # The `Enum` helpers that draw from the calling process's `:rand` dictionary.
  @process_rng_enum_functions [:random, :shuffle, :take_random]

  test "Pidro.Core.Chance is the only module in the domain that reaches :rand" do
    sources = domain_sources()

    assert @chance_source in sources,
           "expected to find #{@chance_source}; has the chance module moved?"

    offenders =
      sources
      |> List.delete(@chance_source)
      |> Enum.flat_map(&process_rng_call_sites/1)

    assert offenders == [], """
    The game domain must draw randomness only through Pidro.Core.Chance, from
    the chance stream carried in %GameState{}. Found process-RNG call sites:

    #{Enum.map_join(offenders, "\n", &("  " <> &1))}
    """
  end

  test "every domain directory is scanned" do
    sources = domain_sources()

    for directory <- @domain_directories do
      assert Enum.any?(sources, &String.starts_with?(&1, directory <> "/")),
             "no sources found under #{directory} — the scan would pass vacuously"
    end
  end

  defp domain_sources do
    @domain_directories
    |> Enum.flat_map(&Path.wildcard(Path.join([@app_root, &1, "**/*.ex"])))
    |> Enum.map(&Path.relative_to(&1, @app_root))
    |> Enum.sort()
  end

  defp process_rng_call_sites(relative_path) do
    path = Path.join(@app_root, relative_path)

    {_ast, offenders} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)
      |> Macro.prewalk([], &collect_call_site(&1, &2, relative_path))

    Enum.reverse(offenders)
  end

  # Type expressions are not code. Returning a leaf prunes the subtree.
  defp collect_call_site({:@, _meta, [{attribute, _, _}]}, offenders, _path)
       when attribute in @type_attributes do
    {:pruned, offenders}
  end

  defp collect_call_site({{:., meta, [:rand, function]}, context, arguments}, offenders, path) do
    # The module atom is rewritten so the clause below does not report the same
    # call a second time; the arguments are still walked.
    {{{:., meta, [:__reported__, function]}, context, arguments},
     [describe(path, meta, ":rand.#{function}/#{length(arguments)}") | offenders]}
  end

  defp collect_call_site(
         {{:., meta, [{:__aliases__, _, [:Enum]}, function]}, _, arguments} = node,
         offenders,
         path
       )
       when function in @process_rng_enum_functions do
    {node, [describe(path, meta, "Enum.#{function}/#{length(arguments)}") | offenders]}
  end

  # Catches the module reached indirectly — `apply(:rand, :uniform, [])` and
  # friends — which the remote-call clause above would not see.
  defp collect_call_site(:rand, offenders, path) do
    {:rand, [describe(path, [], "the :rand module") | offenders]}
  end

  defp collect_call_site(node, offenders, _path), do: {node, offenders}

  defp describe(path, meta, what) do
    case Keyword.get(meta, :line) do
      nil -> "#{path}: #{what}"
      line -> "#{path}:#{line}: #{what}"
    end
  end
end
