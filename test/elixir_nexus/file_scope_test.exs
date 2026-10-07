defmodule ElixirNexus.FileScopeTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.FileScope

  setup do
    root = Path.join(System.tmp_dir!(), "file_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write(root, rel, content \\ "defmodule X do\nend\n") do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "an anchored pattern excludes only the top-level directory, an unanchored one every depth", %{root: root} do
    # Contra's .nexusignore: `/test/` must not drop lib/**/test, `generated/` must
    # drop every generated directory.
    write(root, ".nexusignore", "/test/\ngenerated/\nlib/**/*.gen.ex\n")
    write(root, ".gitignore", "/priv/\n")

    expected_in = ~w(lib/app.ex lib/test/helper.ex lib/deep/test/more.ex mix.exs)
    expected_out = ~w(test/app_test.exs generated/top.ex lib/generated/mid.ex lib/a/generated/deep.ex
                      lib/x/y.gen.ex lib/y.gen.ex priv/repo/seeds.exs node_modules/pkg/index.ex)

    Enum.each(expected_in ++ expected_out, &write(root, &1))

    {:ok, files, _stats} = FileScope.collect(root)
    collected = files |> Enum.map(&Path.relative_to(&1, root)) |> Enum.sort()

    assert collected == Enum.sort(expected_in)

    # The per-path check (watcher, deletions) agrees with the walk on every file.
    for rel <- expected_in, do: assert(FileScope.in_scope?(root, Path.join(root, rel)), rel)
    for rel <- expected_out, do: refute(FileScope.in_scope?(root, Path.join(root, rel)), rel)
  end

  test "a nested .gitignore applies to its own subtree only", %{root: root} do
    write(root, "speech/.gitignore", "public/built/\n")
    built = write(root, "speech/public/built/worker.ex")
    sibling = write(root, "other/public/built/kept.ex")

    refute FileScope.in_scope?(root, built)
    assert FileScope.in_scope?(root, sibling)
  end

  test "a path that does not exist is still classified, so a deletion can be checked", %{root: root} do
    write(root, ".nexusignore", "/docs/\n")

    assert FileScope.in_scope?(root, Path.join(root, "lib/gone.ex"))
    refute FileScope.in_scope?(root, Path.join(root, "docs/gone.ex"))
    refute FileScope.in_scope?(root, Path.join(root, "lib/notes.txt"))
    refute FileScope.in_scope?(root, "/elsewhere/lib/gone.ex")
  end
end
