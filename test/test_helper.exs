exclude = []
exclude = if System.get_env("PYMODBUS_PYTHON"), do: exclude, else: [:interop | exclude]
exclude = if System.get_env("LIBMODBUS_INTEROP"), do: exclude, else: [:libmodbus | exclude]
exclude = if System.get_env("SOAK_SECONDS"), do: exclude, else: [:soak | exclude]
ExUnit.start(exclude: exclude)
