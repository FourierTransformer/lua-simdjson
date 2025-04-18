package="lua-simdjson"
version="scm-1"
source = {
   url = "git://github.com/FourierTransformer/lua-simdjson"
}
description = {
   summary = "This is a simple Lua binding for simdjson",
   detailed = [[
      This is a c++ binding to simdjson for parsing JSON very quickly.
   ]],
   homepage = "https://github.com/FourierTransformer/lua-simdjson",
   license = "Apache-2.0"
}
dependencies = {
   "lua >= 5.1, < 5.5"
}
build = {
   type = "make",
   build_variables = {
      CFLAGS="$(CFLAGS)",
      LIBFLAG="$(LIBFLAG)",
      LUA_BINDIR="$(LUA_BINDIR)",
      LUA_INCDIR="$(LUA_INCDIR)",
      LUA="$(LUA)",
   },
   install_variables = {
      INST_PREFIX="$(PREFIX)",
      INST_BINDIR="$(BINDIR)",
      INST_LIBDIR="$(LIBDIR)",
      INST_LUADIR="$(LUADIR)",
      INST_CONFDIR="$(CONFDIR)",
   },
   platforms = {
      windows = {
         build_variables = {
            LUA_LIBDIR="$(LUA_LIBDIR)",
            LUALIB="$(LUALIB)",
            LD="$(LD)",
         }
      }
   }
}
