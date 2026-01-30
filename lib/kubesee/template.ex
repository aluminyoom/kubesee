defmodule Kubesee.Template do
  @moduledoc false

  alias Kubesee.Event

  @doc """
  Renders a Go-style template string with event context.

  Supports:
  - Field access: `{{ .Field }}`, `{{ .InvolvedObject.Name }}`
  - Helper methods: `{{ .GetTimestampMs }}`, `{{ .GetTimestampISO8601 }}`
  - Sprig functions: `{{ toJson . }}`, `{{ upper .Field }}`, etc.
  - Pipes: `{{ .Field | upper | trim }}`
  - index function: `{{ index .Labels "key" }}`
  """
  @spec render(String.t(), Event.t()) :: {:ok, String.t()} | {:error, term()}
  def render(template, %Event{} = event) when is_binary(template) do
    context = Event.to_template_context(event)
    render_with_context(template, context)
  end

  @spec render_with_context(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_with_context(template, context) when is_binary(template) and is_map(context) do
    case parse_and_render(template, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Converts a layout map by rendering all template strings within it.
  Handles nested maps and lists recursively.
  """
  @spec convert_layout(map() | nil, Event.t()) :: {:ok, map()} | {:error, term()}
  def convert_layout(nil, _event), do: {:ok, nil}

  def convert_layout(layout, %Event{} = event) when is_map(layout) do
    context = Event.to_template_context(event)
    convert_layout_with_context(layout, context)
  end

  defp convert_layout_with_context(layout, context) when is_map(layout) do
    Enum.reduce_while(layout, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case convert_value(value, context) do
        {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert_value(value, context) when is_binary(value) do
    render_with_context(value, context)
  end

  defp convert_value(value, context) when is_map(value) do
    convert_layout_with_context(value, context)
  end

  defp convert_value(value, context) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case convert_value(item, context) do
        {:ok, converted} -> {:cont, {:ok, acc ++ [converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert_value(value, _context), do: {:ok, value}

  defp parse_and_render(template, context) do
    {:ok, parts} = parse_template(template)
    render_parts(parts, context)
  end

  defp parse_template(template) do
    regex = ~r/\{\{(.*?)\}\}/s
    split_parts = Regex.split(regex, template, include_captures: true, trim: false)
    parts = Enum.map(split_parts, &classify_part/1)
    {:ok, parts}
  end

  defp classify_part(part) do
    if String.starts_with?(part, "{{") && String.ends_with?(part, "}}") do
      expr =
        part
        |> String.slice(2..-3//1)
        |> String.trim()

      {:expr, expr}
    else
      {:text, part}
    end
  end

  defp render_parts(parts, context) do
    Enum.reduce_while(parts, {:ok, ""}, fn part, {:ok, acc} ->
      case render_part(part, context) do
        {:ok, rendered} -> {:cont, {:ok, acc <> rendered}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp render_part({:text, text}, _context), do: {:ok, text}

  defp render_part({:expr, expr}, context) do
    case evaluate_expression(expr, context) do
      {:ok, value} -> {:ok, to_string_safe(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp evaluate_expression(expr, context) do
    case parse_expression(expr) do
      {:ok, ast} -> evaluate_ast(ast, context)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_expression(expr) do
    expr = String.trim(expr)

    cond do
      String.contains?(expr, "|") ->
        parse_pipeline(expr)

      String.starts_with?(expr, ".") ->
        {:ok, {:field_access, parse_path(String.slice(expr, 1..-1//1))}}

      true ->
        parse_function_call(expr)
    end
  end

  defp parse_pipeline(expr) do
    parts =
      expr
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    case parts do
      [first | rest] ->
        case parse_expression(first) do
          {:ok, initial_ast} ->
            build_pipeline(initial_ast, rest)

          error ->
            error
        end

      [] ->
        {:error, "empty pipeline"}
    end
  end

  defp build_pipeline(ast, []), do: {:ok, ast}

  defp build_pipeline(ast, [func_str | rest]) do
    case parse_pipeline_function(func_str, ast) do
      {:ok, new_ast} -> build_pipeline(new_ast, rest)
      error -> error
    end
  end

  defp parse_pipeline_function(func_str, input_ast) do
    parts = String.split(func_str, ~r/\s+/, parts: 2)

    case parts do
      [func_name] ->
        {:ok, {:function_call, func_name, [input_ast]}}

      [func_name, args_str] ->
        case parse_function_args(args_str) do
          {:ok, args} -> {:ok, {:function_call, func_name, [input_ast | args]}}
          error -> error
        end
    end
  end

  defp parse_function_call(expr) do
    parts = String.split(expr, ~r/\s+/, parts: 2)

    case parts do
      [func_name] when func_name != "" ->
        {:ok, {:function_call, func_name, []}}

      [func_name, args_str] ->
        case parse_function_args(args_str) do
          {:ok, args} -> {:ok, {:function_call, func_name, args}}
          error -> error
        end

      _ ->
        {:error, "invalid expression: #{expr}"}
    end
  end

  defp parse_function_args(args_str) do
    args_str = String.trim(args_str)

    tokens = tokenize_args(args_str)

    args =
      Enum.map(tokens, fn token ->
        token = String.trim(token)

        cond do
          String.starts_with?(token, ".") ->
            {:field_access, parse_path(String.slice(token, 1..-1//1))}

          String.starts_with?(token, "\"") && String.ends_with?(token, "\"") ->
            {:literal, String.slice(token, 1..-2//1)}

          String.match?(token, ~r/^\d+$/) ->
            {:literal, String.to_integer(token)}

          true ->
            {:literal, token}
        end
      end)

    {:ok, args}
  end

  defp tokenize_args(args_str) do
    ~r/(?:"[^"]*"|\S+)/
    |> Regex.scan(args_str)
    |> List.flatten()
  end

  defp parse_path(""), do: []

  defp parse_path(path) do
    path
    |> String.split(".")
    |> Enum.reject(&(&1 == ""))
  end

  defp evaluate_ast({:field_access, []}, context), do: {:ok, context}

  defp evaluate_ast({:field_access, path}, context) do
    {:ok, get_nested(context, path)}
  end

  defp evaluate_ast({:literal, value}, _context), do: {:ok, value}

  defp evaluate_ast({:function_call, func_name, args}, context) do
    evaluated_args =
      Enum.map(args, fn arg ->
        case evaluate_ast(arg, context) do
          {:ok, value} -> value
          {:error, _} = err -> throw(err)
        end
      end)

    call_function(func_name, evaluated_args)
  catch
    {:error, reason} -> {:error, reason}
  end

  defp get_nested(context, []), do: maybe_call_function(context)

  defp get_nested(context, [key | rest]) when is_map(context) do
    value = Map.get(context, key) || Map.get(context, String.to_atom(key))
    get_nested(value, rest)
  end

  defp get_nested(nil, _), do: nil
  defp get_nested(_, _), do: nil

  defp maybe_call_function(fun) when is_function(fun, 0), do: fun.()
  defp maybe_call_function(value), do: value

  defp call_function("toJson", [value]) do
    {:ok, Jason.encode!(filter_functions(value))}
  rescue
    _ -> {:ok, "null"}
  end

  defp call_function("toPrettyJson", [value]) do
    {:ok, Jason.encode!(filter_functions(value), pretty: true)}
  rescue
    _ -> {:ok, "null"}
  end

  defp call_function("quote", [value]) do
    {:ok, "\"#{to_string_safe(value)}\""}
  end

  defp call_function("squote", [value]) do
    {:ok, "'#{to_string_safe(value)}'"}
  end

  defp call_function("upper", [value]) do
    {:ok, String.upcase(to_string_safe(value))}
  end

  defp call_function("lower", [value]) do
    {:ok, String.downcase(to_string_safe(value))}
  end

  defp call_function("trim", [value]) do
    {:ok, String.trim(to_string_safe(value))}
  end

  defp call_function("replace", [old, new, value]) do
    {:ok, String.replace(to_string_safe(value), to_string_safe(old), to_string_safe(new))}
  end

  defp call_function("contains", [substr, value]) do
    {:ok, String.contains?(to_string_safe(value), to_string_safe(substr))}
  end

  defp call_function("hasPrefix", [prefix, value]) do
    {:ok, String.starts_with?(to_string_safe(value), to_string_safe(prefix))}
  end

  defp call_function("hasSuffix", [suffix, value]) do
    {:ok, String.ends_with?(to_string_safe(value), to_string_safe(suffix))}
  end

  defp call_function("default", [default_val, value]) do
    if empty?(value) do
      {:ok, default_val}
    else
      {:ok, value}
    end
  end

  defp call_function("empty", [value]) do
    {:ok, empty?(value)}
  end

  defp call_function("coalesce", args) do
    result = Enum.find(args, fn arg -> !empty?(arg) end)
    {:ok, result}
  end

  defp call_function("now", []) do
    utc_now = DateTime.utc_now()
    {:ok, DateTime.to_iso8601(utc_now)}
  end

  defp call_function("index", [collection, key]) when is_map(collection) do
    {:ok, Map.get(collection, key) || Map.get(collection, to_string(key))}
  end

  defp call_function("index", [collection, index]) when is_list(collection) and is_integer(index) do
    {:ok, Enum.at(collection, index)}
  end

  defp call_function("index", [nil, _key]), do: {:ok, nil}

  defp call_function(func_name, _args) do
    {:error, "unknown function: #{func_name}"}
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?(map) when is_map(map), do: map_size(map) == 0
  defp empty?([]), do: true
  defp empty?(list) when is_list(list), do: false
  defp empty?(_), do: false

  defp filter_functions(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_function(v) end)
    |> Enum.map(fn {k, v} -> {k, filter_functions(v)} end)
    |> Map.new()
  end

  defp filter_functions(list) when is_list(list) do
    Enum.map(list, &filter_functions/1)
  end

  defp filter_functions(value), do: value

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(value) when is_float(value), do: Float.to_string(value)
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(true), do: "true"
  defp to_string_safe(false), do: "false"
  defp to_string_safe(value) when is_map(value), do: Jason.encode!(filter_functions(value))
  defp to_string_safe(value) when is_list(value), do: Jason.encode!(filter_functions(value))
  defp to_string_safe(fun) when is_function(fun, 0), do: to_string_safe(fun.())
  defp to_string_safe(value), do: inspect(value)
end
