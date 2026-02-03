defmodule Kubesee.Sinks.File do
  @moduledoc false

  use GenServer

  @behaviour Kubesee.Sink

  import Kubesee.Sinks.Common, only: [maybe_dedot: 2, serialize_event: 2]

  @default_max_size_mb 100
  @default_max_backups 0
  @default_max_age 0
  @max_backup_iterations 999

  @impl Kubesee.Sink
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl Kubesee.Sink
  def send(sink, event) do
    GenServer.call(sink, {:send, event})
  end

  @impl Kubesee.Sink
  def close(sink) do
    GenServer.stop(sink)
  end

  @impl GenServer
  def init(config) do
    path = config["path"]

    case File.open(path, [:write, :append]) do
      {:ok, file} ->
        state = %{
          config: config,
          path: path,
          file: file,
          current_size: get_file_size(path),
          max_size: (config["maxsize"] || @default_max_size_mb) * 1024 * 1024,
          max_backups: config["maxbackups"] || @default_max_backups,
          max_age: config["maxage"] || @default_max_age
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, event}, _from, state) do
    event = maybe_dedot(event, state.config)

    case serialize_event(event, state.config) do
      {:ok, json} ->
        data = json <> "\n"
        data_size = byte_size(data)

        state = maybe_rotate(state, data_size)

        case IO.binwrite(state.file, data) do
          :ok ->
            {:reply, :ok, %{state | current_size: state.current_size + data_size}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{file: file}) when not is_nil(file) do
    File.close(file)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _} -> 0
    end
  end

  defp maybe_rotate(state, data_size) do
    if state.current_size + data_size > state.max_size and state.max_size > 0 do
      rotate_file(state)
    else
      state
    end
  end

  defp rotate_file(state) do
    File.close(state.file)

    shift_backups(state.path, state.max_backups)

    cleanup_old_backups(state.path, state.max_backups)
    cleanup_old_age(state.path, state.max_age)

    case File.open(state.path, [:write, :append]) do
      {:ok, file} ->
        %{state | file: file, current_size: 0}

      {:error, _reason} ->
        state
    end
  end

  defp shift_backups(path, max_backups) do
    max = if max_backups == 0, do: @max_backup_iterations, else: max_backups

    Enum.each(max..1//-1, fn n ->
      old_path = "#{path}.#{n}"
      new_path = "#{path}.#{n + 1}"

      if File.exists?(old_path) do
        File.rename(old_path, new_path)
      end
    end)

    if File.exists?(path) do
      File.rename(path, "#{path}.1")
    end
  end

  defp cleanup_old_backups(_path, 0), do: :ok

  defp cleanup_old_backups(path, max_backups) do
    Enum.each((max_backups + 1)..@max_backup_iterations, fn n ->
      backup_path = "#{path}.#{n}"

      if File.exists?(backup_path) do
        File.rm(backup_path)
      end
    end)
  end

  defp cleanup_old_age(_path, 0), do: :ok

  defp cleanup_old_age(path, max_age_days) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -max_age_days * 24 * 3600, :second)

    Enum.each(1..@max_backup_iterations, &maybe_delete_old_backup(&1, path, cutoff))
  end

  defp maybe_delete_old_backup(n, path, cutoff) do
    backup_path = "#{path}.#{n}"

    with true <- File.exists?(backup_path),
         {:ok, %{mtime: mtime}} <- File.stat(backup_path),
         mtime_dt <- mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC"),
         :lt <- DateTime.compare(mtime_dt, cutoff) do
      File.rm(backup_path)
    end
  end
end
