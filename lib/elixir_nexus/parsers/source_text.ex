defmodule ElixirNexus.Parsers.SourceText do
  @moduledoc """
  Source-text helpers for the extractors' content-enrichment passes, which look
  for imported names in a function's raw source to recover calls the NIF drops.
  """

  # One left-to-right pass: whichever of a comment or a string starts first wins,
  # so `//` inside a string and quotes inside a comment are handled correctly.
  @js_noise ~r{//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'}s
  @python_noise ~r{"""[\s\S]*?"""|'''[\s\S]*?'''|#[^\n]*|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'}

  @doc """
  Blank out comments and plain string literals so a name search only sees code.

  JS/TS template literals are kept: `${...}` can hold real calls. Python
  f-strings are blanked like other strings, a rare miss.
  """
  @spec code_only(String.t(), :js | :python) :: String.t()
  def code_only(content, :js), do: Regex.replace(@js_noise, content, &blank/1)
  def code_only(content, :python), do: Regex.replace(@python_noise, content, &blank/1)

  defp blank(match) do
    if String.starts_with?(match, ["\"", "'"]), do: ~s(""), else: " "
  end
end
