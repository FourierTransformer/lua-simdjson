#ifndef LUA_SIMDJSON_ENCODER_H
#define LUA_SIMDJSON_ENCODER_H

#include <lua.hpp>

int encode(lua_State *L);
int set_max_encode_depth(lua_State *L);
int get_max_encode_depth(lua_State *L);
int set_encode_buffer_size(lua_State *L);
int get_encode_buffer_size(lua_State *L);

#endif
