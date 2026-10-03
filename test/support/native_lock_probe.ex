defmodule AtMcp.Test.NativeLockProbe do
  @moduledoc false

  # System.cmd closes inherited descriptors itself on some OTP/platform paths,
  # so its child cannot by itself falsify a missing O_CLOEXEC on the lock. This
  # separate test NIF observes fcntl on the live descriptor by file identity.
  # It is never compiled into the application's production native library.
  def load! do
    target = Path.join(System.tmp_dir!(), "at-mcp-lock-probe-#{System.pid()}")
    include = Path.join([to_string(:code.root_dir()), "usr", "include"])

    flags =
      if match?({:unix, :darwin}, :os.type()),
        do: ["-dynamiclib", "-undefined", "dynamic_lookup"],
        else: ["-shared", "-fPIC"]

    source = Path.expand("native_lock_probe.c", __DIR__)

    try do
      {output, status} =
        System.cmd("cc", flags ++ ["-I", include, "-o", target <> ".so", source],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("native lock probe compilation failed: #{output}")
      :ok = :erlang.load_nif(String.to_charlist(target), 0)
    after
      File.rm(target <> ".so")
    end
  end

  def close_on_exec?(_path), do: :erlang.nif_error(:nif_not_loaded)
end
