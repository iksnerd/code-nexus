defmodule ElixirNexus.Search.Builtins do
  @moduledoc """
  Language builtins and standard-library qualifiers. Calls to these are not
  relationships between project entities, so rankings ignore them: otherwise
  every Python `len(...)` makes a project function named `len` a hub, and every
  `Map.get` / `Logger.info` credits an Elixir function named `get` / `info`.
  """

  @unqualified %{
    "python" => ~w(
      abs all any bool bytes callable chr dict dir divmod enumerate filter float format
      frozenset getattr globals hasattr hash hex id input int isinstance issubclass iter
      len list locals map max min next object oct open ord pow print property range repr
      reversed round set setattr slice sorted staticmethod classmethod str sum super tuple
      type vars zip Exception ValueError TypeError KeyError RuntimeError NotImplementedError
    ),
    "go" => ~w(append cap clear close complex copy delete imag len make max min new panic print println real recover),
    "js" => ~w(
      Array ArrayBuffer Boolean Date Error Map Math Number Object Promise Proxy RangeError
      Reflect RegExp Set String Symbol TypeError URL URLSearchParams WeakMap WeakSet JSON
      console clearInterval clearTimeout decodeURIComponent encodeURIComponent fetch
      isNaN parseFloat parseInt queueMicrotask require setInterval setTimeout structuredClone
    ),
    "elixir" => ~w(
      apply elem hd inspect is_atom is_binary is_integer is_list is_map is_nil length
      map_size put_elem raise send spawn throw tl to_string tuple_size
    )
  }

  @stdlib_qualifiers %{
    "python" => ~w(os sys json re math time logging random itertools functools collections pathlib typing),
    "go" => ~w(fmt strings strconv os io errors sync time context log http filepath bytes sort json math rand atomic),
    "js" => ~w(console JSON Math Object Array Promise Number Date String Reflect process window document),
    "elixir" => ~w(
      Access Agent Application Atom Base Code DateTime Date Enum File Float Function GenServer
      Integer IO Jason Kernel Keyword List Logger Map MapSet Module NaiveDateTime Path Process
      Range Regex Registry Stream String Supervisor System Task Time Tuple URI
    )
  }

  @doc "Language family key: JS/TS/TSX/JSX share one set."
  def family(lang) when lang in [nil, ""], do: nil

  def family(lang) do
    case to_string(lang) do
      l when l in ["typescript", "tsx", "javascript", "jsx"] -> "js"
      l -> l
    end
  end

  @doc "True when `call` (as written at the call site) is a builtin or stdlib call in `lang`."
  def builtin_call?(call, lang) do
    family = family(lang)

    case String.split(to_string(call), ".") do
      [name] -> name in Map.get(@unqualified, family, [])
      [qualifier | _] -> qualifier in Map.get(@stdlib_qualifiers, family, [])
    end
  end
end
