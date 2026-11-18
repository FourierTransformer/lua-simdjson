#include <lua.hpp>

#include "lua_encoder.h"

#ifdef _MSC_VER
#define LUASIMDJSON_EXPORT __declspec(dllexport)
#else
#define LUASIMDJSON_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {
static int parse(lua_State *);
static int parse_file(lua_State *);
static int active_implementation(lua_State *);
static int ParsedObject_open(lua_State *);
static int ParsedObject_open_file(lua_State *);
static int set_max_decode_depth(lua_State *);
static int get_max_decode_depth(lua_State *);
static int set_decode_buffer_size(lua_State *);
static int get_decode_buffer_size(lua_State *);
static int debug_decode_capacities(lua_State *);
static const struct luaL_Reg luasimdjson[] = {
    {"parse", parse},
    {"parseFile", parse_file},
    {"activeImplementation", active_implementation},
    {"open", ParsedObject_open},
    {"openFile", ParsedObject_open_file},
    {"setMaxDecodeDepth", set_max_decode_depth},
    {"getMaxDecodeDepth", get_max_decode_depth},
    {"setDecodeBufferSize", set_decode_buffer_size},
    {"getDecodeBufferSize", get_decode_buffer_size},
    {"_debugDecodeCapacities", debug_decode_capacities},
    {"encode", encode},
    {"setMaxEncodeDepth", set_max_encode_depth},
    {"getMaxEncodeDepth", get_max_encode_depth},
    {"setEncodeBufferSize", set_encode_buffer_size},
    {"getEncodeBufferSize", get_encode_buffer_size},

    {NULL, NULL},
};
LUASIMDJSON_EXPORT int luaopen_simdjson(lua_State *);
}
