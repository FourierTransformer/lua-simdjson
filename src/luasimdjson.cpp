#include <lua.hpp>
#include <lauxlib.h>

#ifdef _WIN32
#include <windows.h>
#include <sysinfoapi.h>
#else
#include <unistd.h>
#endif

#define NDEBUG
#define __OPTIMIZE__ 1

#include "simdjson.h"
#include "luasimdjson.h"

#define LUA_SIMDJSON_NAME       "simdjson"
#define LUA_SIMDJSON_VERSION    "0.0.3"

using namespace simdjson;

#if !defined(luaL_newlibtable) && (!defined LUA_VERSION_NUM || LUA_VERSION_NUM<=501)
/*
** set_funcs compat for 5.1
** Stolen from: http://lua-users.org/wiki/CompatibilityWithLuaFive
** Adapted from Lua 5.2.0
*/
static void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup) {
  luaL_checkstack(L, nup+1, "too many upvalues");
  for (; l->name != NULL; l++) {  /* fill the table with given functions */
    int i;
    lua_pushstring(L, l->name);
    for (i = 0; i < nup; i++)  /* copy upvalues to the top */
      lua_pushvalue(L, -(nup+1));
    lua_pushcclosure(L, l->func, nup);  /* closure with those upvalues */
    lua_settable(L, -(nup + 3));
  }
  lua_pop(L, nup);  /* remove upvalues */
}
#endif

ondemand::parser ondemand_parser;
simdjson::padded_string jsonbuffer;

void convert_ondemand_element_to_table(lua_State *L, ondemand::value element) {
  switch (element.type()) {

    case ondemand::json_type::array:
      {
          int count = 1;
          lua_newtable(L);

            for (auto child : element.get_array()) {
              lua_pushinteger(L, count);
              // We need the call to value() to get
              // an ondemand::value type.
              convert_ondemand_element_to_table(L, child.value());
              lua_settable(L, -3);
              count = count + 1;
            }
            break;
      }

    case ondemand::json_type::object:
      lua_newtable(L);
      for (auto field : element.get_object()) {
        std::string_view s = field.escaped_key();
        lua_pushlstring(L, s.data(), s.size());
        convert_ondemand_element_to_table(L, field.value());
        lua_settable(L, -3);
      }
      break;

    case ondemand::json_type::number:
      {
        ondemand::number number = element.get_number();
        ondemand::number_type number_type = number.get_number_type();
        switch (number_type) {
          case fallback::number_type::floating_point_number:
          lua_pushnumber(L, element.get_double());
          break;

          case fallback::number_type::signed_integer:
          lua_pushinteger(L, element.get_int64());
          break;

          case fallback::number_type::unsigned_integer:
          {
            // a uint64 can be greater than an int64, so we must check how large and pass as a number
            // if larger but LUA_MAXINTEGER (which is only defined in 5.3+)
            #if defined(LUA_MAXINTEGER)
            uint64_t actual_value = element.get_uint64();
            if (actual_value > LUA_MAXINTEGER) {
              lua_pushnumber(L, actual_value);
            } else {
              lua_pushinteger(L, actual_value);
            }
            #else
            lua_pushnumber(L, element.get_double());
            #endif
            break;
          }

          case fallback::number_type::big_integer:
          lua_pushnumber(L, element.get_double());
          break;
        }
        break;
      }

    case ondemand::json_type::string:
      {
        std::string_view s = element.get_string();
        lua_pushlstring(L, s.data(), s.size());
        break;
      }

    case ondemand::json_type::boolean:
      lua_pushboolean(L, element.get_bool());
      break;

    case ondemand::json_type::null:
      lua_pushlightuserdata(L, NULL);
      break;
  }
}

// from https://github.com/simdjson/simdjson/blob/master/doc/performance.md#free-padding
// Returns the default size of the page in bytes on this system.
long page_size() {
#ifdef _WIN32
  SYSTEM_INFO sysInfo;
  GetSystemInfo(&sysInfo);
  long pagesize = sysInfo.dwPageSize;
#else
  long pagesize = sysconf(_SC_PAGESIZE);
#endif
  return pagesize;
}

// allows us to reuse a json buffer pretty safely
// Returns true if the buffer + len + simdjson::SIMDJSON_PADDING crosses the
// page boundary.
bool need_allocation(const char *buf, size_t len) {
  return ((reinterpret_cast<uintptr_t>(buf + len - 1) % page_size()) <
          simdjson::SIMDJSON_PADDING);
}

simdjson::padded_string_view get_padded_string_view(const char *buf, size_t len,
                       simdjson::padded_string &jsonbuffer) {
  if (need_allocation(buf, len)) { // unlikely case
    jsonbuffer = simdjson::padded_string(buf, len);
    return jsonbuffer;
  } else { // no reallcation needed (very likely)
    return simdjson::padded_string_view(buf, len,
                                            len + simdjson::SIMDJSON_PADDING);
  }
}

static int parse(lua_State *L)
{
    size_t json_str_len;
    const char *json_str = luaL_checklstring(L, 1, &json_str_len);

    ondemand::document doc;
    ondemand::value element;

    try {
        // makes a padded_string_view for a bit of quickness!
        doc = ondemand_parser.iterate(get_padded_string_view(json_str, json_str_len, jsonbuffer));
        element = doc;
        convert_ondemand_element_to_table(L, element);
    } catch (simdjson::simdjson_error &error) {
        luaL_error(L, error.what());
    }

    return 1;
}

static int parse_file(lua_State *L)
{
    const char *json_file = luaL_checkstring(L, 1);

    padded_string json_string;
    ondemand::document doc;
    ondemand::value element;

    try {
        json_string = padded_string::load(json_file);
        doc = ondemand_parser.iterate(json_string);
        element = doc;
        convert_ondemand_element_to_table(L, element);
    } catch (simdjson::simdjson_error &error) {
        luaL_error(L, error.what());
    }

    return 1;
}

static int active_implementation(lua_State *L)
{
    const auto& implementation = simdjson::get_active_implementation();
    std::string name = implementation->name();
    const std::string description = implementation->description();
    const std::string implementation_name = name + " (" + description + ")";

    lua_pushlstring(L, implementation_name.data(), implementation_name.size());

    return 1;
}


// ParsedObject as C++ class
#define LUA_MYOBJECT "ParsedObject"
class ParsedObject {
private:
  simdjson::padded_string json_string;
  ondemand::document doc;
  std::unique_ptr<ondemand::parser> parser;

public:
  ParsedObject(const char *json_file)
      : json_string(padded_string::load(json_file)),
        parser(new ondemand::parser{}) {
    this->doc = this->parser.get()->iterate(json_string);
  }
  ParsedObject(const char *json_str, size_t json_str_len)
      : json_string(json_str, json_str_len),
        parser(new ondemand::parser{}) {
    this->doc = this->parser.get()->iterate(json_string);
  }
  ~ParsedObject() {}
  ondemand::document *get_doc() { return &(this->doc); }
};

static int ParsedObject_delete(lua_State *L) {
  delete *reinterpret_cast<ParsedObject **>(lua_touserdata(L, 1));
  return 0;
}

static int ParsedObject_open(lua_State *L) {
  size_t json_str_len;
  const char *json_str = luaL_checklstring(L, 1, &json_str_len);

  try {
    ParsedObject **parsedObject =
        (ParsedObject **)(lua_newuserdata(L, sizeof(ParsedObject *)));
    *parsedObject = new ParsedObject(json_str, json_str_len);
    luaL_getmetatable(L, LUA_MYOBJECT);
    lua_setmetatable(L, -2);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }
  return 1;
}

static int ParsedObject_open_file(lua_State *L) {
  const char *json_file = luaL_checkstring(L, 1);

  simdjson::padded_string json_string;
  ondemand::document doc;

  try {
    ParsedObject **parsedObject =
        (ParsedObject **)(lua_newuserdata(L, sizeof(ParsedObject *)));
    *parsedObject = new ParsedObject(json_file);
    luaL_getmetatable(L, LUA_MYOBJECT);
    lua_setmetatable(L, -2);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }

  return 1;
}

static int ParsedObject_atPointer(lua_State *L) {
  ondemand::document *document =
      (*reinterpret_cast<ParsedObject **>(luaL_checkudata(L, 1, LUA_MYOBJECT)))
          ->get_doc();
  const char *pointer = luaL_checkstring(L, 2);

  try {
    ondemand::value returned_element = document->at_pointer(pointer);
    convert_ondemand_element_to_table(L, returned_element);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }

  return 1;
}

static int ParsedObject_newindex(lua_State *L) {
    luaL_error(L, "This should be treated as a read-only table. We may one day add array access for the elements, and it'll likely not be modifiable.");
    return 1;
}

static const struct luaL_Reg arraylib_m [] = {
    {"at", ParsedObject_atPointer},
    {"atPointer", ParsedObject_atPointer},
    {"__newindex", ParsedObject_newindex},
    {"__gc", ParsedObject_delete},
    {NULL, NULL}
};

int luaopen_simdjson (lua_State *L) {
    luaL_newmetatable(L, LUA_MYOBJECT);
     lua_pushvalue(L, -1); /* duplicates the metatable */
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, arraylib_m, 0);

    // luaL_newlib(L, luasimdjson);

    lua_newtable(L);
    luaL_setfuncs (L, luasimdjson, 0);

    lua_pushlightuserdata(L, NULL);
    lua_setfield(L, -2, "null");

    lua_pushliteral(L, LUA_SIMDJSON_NAME);
    lua_setfield(L, -2, "_NAME");
    lua_pushliteral(L, LUA_SIMDJSON_VERSION);
    lua_setfield(L, -2, "_VERSION");

    return 1;
}
