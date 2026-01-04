#include <cmath>
#include <lua.hpp>
#include <lauxlib.h>

#ifdef _WIN32
#include <sysinfoapi.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

#define NDEBUG
#define __OPTIMIZE__ 1

#include "luasimdjson.h"
#include "simdjson.h"

#define LUA_SIMDJSON_NAME "simdjson"
#define LUA_SIMDJSON_VERSION "0.0.8"

// keys encode max depth configuration.
#define LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY "simdjson.max_encode_depth"
#define DEFAULT_MAX_ENCODE_DEPTH simdjson::DEFAULT_MAX_DEPTH

// Encode buffer size reservation configuration
#define LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY "simdjson.encode_buffer_size"
#define DEFAULT_ENCODE_BUFFER_SIZE (16 * 1024) // 16KB
#define DEFAULT_MAX_ENCODE_BUFFER_SIZE simdjson::SIMDJSON_MAXSIZE_BYTES

using namespace simdjson;

#if !defined(luaL_newlibtable) && (!defined LUA_VERSION_NUM || LUA_VERSION_NUM <= 501)
/*
** set_funcs compat for 5.1
** Stolen from: http://lua-users.org/wiki/CompatibilityWithLuaFive
** Adapted from Lua 5.2.0
*/
static void luaL_setfuncs(lua_State *L, const luaL_Reg *l, int nup) {
  luaL_checkstack(L, nup + 1, "too many upvalues");
  for (; l->name != NULL; l++) { /* fill the table with given functions */
    int i;
    lua_pushstring(L, l->name);
    for (i = 0; i < nup; i++) /* copy upvalues to the top */
      lua_pushvalue(L, -(nup + 1));
    lua_pushcclosure(L, l->func, nup); /* closure with those upvalues */
    lua_settable(L, -(nup + 3));
  }
  lua_pop(L, nup); /* remove upvalues */
}
#endif

ondemand::parser ondemand_parser;
simdjson::padded_string jsonbuffer;
thread_local simdjson::builder::string_builder *encode_buffer = nullptr; // Reused across encode() calls
thread_local size_t encode_buffer_size = 0;                              // Track current buffer size

template <typename T> void convert_ondemand_element_to_table(lua_State *L, T &element) {
  static_assert(std::is_base_of<ondemand::document, T>::value || std::is_base_of<ondemand::value, T>::value, "type parameter must be document or value");

  switch (element.type()) {
    case ondemand::json_type::array: {
      int count = 1;
      lua_newtable(L);

      for (ondemand::value child : element.get_array()) {
        lua_pushinteger(L, count);
        convert_ondemand_element_to_table(L, child);
        lua_settable(L, -3);
        count = count + 1;
      }
      break;
    }

    case ondemand::json_type::object:
      lua_newtable(L);
      for (ondemand::field field : element.get_object()) {
        std::string_view s = field.unescaped_key();
        lua_pushlstring(L, s.data(), s.size());
        convert_ondemand_element_to_table(L, field.value());
        lua_settable(L, -3);
      }
      break;

    case ondemand::json_type::number: {
      ondemand::number number = element.get_number();
      ondemand::number_type number_type = number.get_number_type();
      switch (number_type) {
        case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::floating_point_number:
          lua_pushnumber(L, element.get_double());
          break;

        case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::signed_integer:
          lua_pushinteger(L, element.get_int64());
          break;

        case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::unsigned_integer: {
// a uint64 can be greater than an int64, so we must check how large and pass as
// a number if larger but LUA_MAXINTEGER (which is only defined in 5.3+)
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

        case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::big_integer:
          lua_pushnumber(L, element.get_double());
          break;
      }
      break;
    }

    case ondemand::json_type::string: {
      std::string_view s = element.get_string();
      lua_pushlstring(L, s.data(), s.size());
      break;
    }

    case ondemand::json_type::boolean:
      lua_pushboolean(L, element.get_bool());
      break;

    case ondemand::json_type::null:
      // calling is_null().value() will trigger an exception if the value
      // is invalid
      if (element.is_null().value()) {
        lua_pushlightuserdata(L, NULL);
      }
      break;

    case ondemand::json_type::unknown:
    default:
      luaL_error(L, "simdjson::ondemand::json_type::unknown or unsupported "
                    "type "
                    "encountered");
      break;
  }
}

// from
// https://github.com/simdjson/simdjson/blob/master/doc/performance.md#free-padding
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
  return ((reinterpret_cast<uintptr_t>(buf + len - 1) % page_size()) < simdjson::SIMDJSON_PADDING);
}

simdjson::padded_string_view get_padded_string_view(const char *buf, size_t len, simdjson::padded_string &jsonbuffer) {
  if (need_allocation(buf, len)) { // unlikely case
    jsonbuffer = simdjson::padded_string(buf, len);
    return jsonbuffer;
  } else { // no reallcation needed (very likely)
    return simdjson::padded_string_view(buf, len, len + simdjson::SIMDJSON_PADDING);
  }
}

static int parse(lua_State *L) {
  size_t json_str_len;
  const char *json_str = luaL_checklstring(L, 1, &json_str_len);

  ondemand::document doc;

  try {
    // makes a padded_string_view for a bit of quickness!
    doc = ondemand_parser.iterate(get_padded_string_view(json_str, json_str_len, jsonbuffer));
    convert_ondemand_element_to_table(L, doc);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }

  return 1;
}

static int parse_file(lua_State *L) {
  const char *json_file = luaL_checkstring(L, 1);

  padded_string json_string;
  ondemand::document doc;

  try {
    json_string = padded_string::load(json_file);
    doc = ondemand_parser.iterate(json_string);
    convert_ondemand_element_to_table(L, doc);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }

  return 1;
}

static int active_implementation(lua_State *L) {
  const auto &implementation = simdjson::get_active_implementation();
  std::string name = implementation->name();
  const std::string description = implementation->description();
  const std::string implementation_name = name + " (" + description + ")";

  lua_pushlstring(L, implementation_name.data(), implementation_name.size());

  return 1;
}

// Add forward declaration near the top after includes
static void serialize_data(lua_State *L, int current_depth, int max_depth, simdjson::builder::string_builder &builder);

// Helper function to get max encode depth from registry
static int get_max_depth(lua_State *L) {
  lua_pushstring(L, LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY);
  lua_gettable(L, LUA_REGISTRYINDEX);

  int max_depth = DEFAULT_MAX_ENCODE_DEPTH;
  if (lua_isnumber(L, -1)) {
    max_depth = lua_tointeger(L, -1);
  }
  lua_pop(L, 1);

  return max_depth;
}

// Helper function to set max encode depth in registry
static void set_max_depth(lua_State *L, int max_depth) {
  lua_pushstring(L, LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY);
  lua_pushinteger(L, max_depth);
  lua_settable(L, LUA_REGISTRYINDEX);
}

// Helper function to get encode buffer size from registry
static size_t get_encode_buffer_size(lua_State *L) {
  lua_pushstring(L, LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY);
  lua_gettable(L, LUA_REGISTRYINDEX);

  size_t buffer_size = DEFAULT_ENCODE_BUFFER_SIZE;
  if (lua_isnumber(L, -1)) {
    buffer_size = lua_tointeger(L, -1);
  }
  lua_pop(L, 1);

  return buffer_size;
}

// Helper function to set encode buffer size in registry
static void set_encode_buffer_size(lua_State *L, size_t buffer_size) {
  lua_pushstring(L, LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY);
  lua_pushinteger(L, buffer_size);
  lua_settable(L, LUA_REGISTRYINDEX);
}

// Check if table on stack top is a valid array and return its length
// Returns -1 if not an array, otherwise returns maximum index
static int get_table_array_size(lua_State *L) {
  double key_num;
  int max_index = 0;
  int element_count = 0;

  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    // Check if key is a number
    if (lua_type(L, -2) == LUA_TNUMBER) {
      key_num = lua_tonumber(L, -2);
      // Check if it's a positive integer
      if (floor(key_num) == key_num && key_num >= 1) {
        if (static_cast<int>(key_num) > max_index) {
          max_index = static_cast<int>(key_num);
        }
        element_count++;
        lua_pop(L, 1);
        continue;
      }
    }

    // Non-integer key found - not an array
    lua_pop(L, 2);
    return -1;
  }

  // Check if array is contiguous (element count should equal max index)
  if (element_count > 0 && element_count != max_index) {
    return -1;
  }

  return max_index;
}

// Helper function to format a number as a string
// Returns pointer to thread-local buffer and length
inline std::pair<const char *, size_t> format_number_as_string(lua_State *L, int index) {
  thread_local char buffer[32];
  size_t len;

  // JSON numbers are represented as doubles, which have limited precision
  // for integers beyond 2^53. Check this first regardless of Lua version.
#if defined(LUA_MAXINTEGER)
  const double max_safe_int = LUA_MAXINTEGER;
#else
  const double max_safe_int = 9007199254740992.0; // 2^53
#endif

#if LUA_VERSION_NUM >= 503
  // Lua 5.3+ has native integer type
  if (lua_isinteger(L, index)) {
    lua_Integer num = lua_tointeger(L, index);
    // Check if the integer fits safely in a JSON number (double)
    if (num > -max_safe_int && num < max_safe_int) {
      len = snprintf(buffer, sizeof(buffer), "%lld", (long long)num);
      return {buffer, len};
    }
    // Too large for safe integer representation, format as float
    len = snprintf(buffer, sizeof(buffer), "%.14g", (double)num);
    return {buffer, len};
  }
#else
  // For Lua 5.1/5.2, check if the number is an integer value
  {
    double num = lua_tonumber(L, index);
    if (std::floor(num) == num && num <= LLONG_MAX && num >= LLONG_MIN) {
      if (num > -max_safe_int && num < max_safe_int) {
        len = snprintf(buffer, sizeof(buffer), "%lld", static_cast<long long>(num));
        return {buffer, len};
      }
    }
  }
#endif

  // For floats or large numbers, convert to string with %.14g
  lua_Number num = lua_tonumber(L, index);
  len = snprintf(buffer, sizeof(buffer), "%.14g", (double)num);
  return {buffer, len};
}

inline void serialize_append_bool(lua_State *L, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder, int lindex) {
  // check if it is really a boolean
  if (lua_isboolean(L, lindex)) {
    if (lua_toboolean(L, lindex)) {
// Use append_raw with string_view for batched append (more efficient than multiple char appends)
#if __cplusplus >= 202002L
      builder.append(true);
#else
      builder.append_raw(std::string_view("true", 4));
#endif
    } else {
#if __cplusplus >= 202002L
      builder.append(false);
#else
      builder.append_raw(std::string_view("false", 5));
#endif
    }
  } else {
    builder.append_null();
  }
};

static void serialize_append_number(lua_State *L, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder, int lindex) {
  auto num_result = format_number_as_string(L, lindex);
  const char *num_str = num_result.first;
  size_t len = num_result.second;
  // Use append_raw with string_view for numbers (no quotes)
  builder.append_raw(std::string_view(num_str, len));
};

static void serialize_append_string(lua_State *L, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder, int lindex) {
  size_t len;
  const char *str = lua_tolstring(L, lindex, &len);
  builder.escape_and_append_with_quotes(str);
};

static void serialize_append_array(lua_State *L, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder, int table_index, int array_size,
                                   int current_depth, int max_depth) {
  bool first = true;
  // Get the actual stack index if using relative indexing
  if (table_index < 0 && table_index > LUA_REGISTRYINDEX) {
    table_index = lua_gettop(L) + table_index + 1;
  }

  builder.start_array();

  for (int i = 1; i <= array_size; i++) {
    if (!first) {
      builder.append_comma();
    }
    first = false;

    // Push the value at index i onto the stack
    lua_rawgeti(L, table_index, i);

    // Serialize the value
    serialize_data(L, current_depth, max_depth, builder);
    // Pop the value from the stack
    lua_pop(L, 1);
  }

  builder.end_array();
}

static void serialize_append_object(lua_State *L, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder, int current_depth, int max_depth) {
  builder.start_object();
  bool first = true;

  // Start iteration with nil key
  lua_pushnil(L);

  while (lua_next(L, -2) != 0) {
    if (!first) {
      builder.append_comma();
    }
    first = false;

    // Cache key type to avoid multiple lua_type calls
    int key_type = lua_type(L, -2);

    // Serialize the key
    if (key_type == LUA_TSTRING) {
      size_t key_len;
      const char *key = lua_tolstring(L, -2, &key_len);
      // Always use the proper escape function for string keys
      builder.escape_and_append_with_quotes(std::string_view(key, key_len));
    } else if (key_type == LUA_TNUMBER) {
      auto key_result = format_number_as_string(L, -2);
      const char *key_str = key_result.first;
      size_t key_len = key_result.second;
      // Numeric keys are formatted as strings with quotes
      builder.append('"');
      for (size_t i = 0; i < key_len; i++) {
        builder.append(key_str[i]);
      }
      builder.append('"');
    } else {
      const char *type_name = lua_typename(L, key_type);
      luaL_error(L, "unsupported key type in table for serialization: %s", type_name);
    }

    builder.append_colon();

    // Serialize the value (it's already on top of stack)
    serialize_data(L, current_depth, max_depth, builder);
    // Pop value, keep key for next iteration
    lua_pop(L, 1);
  }

  builder.end_object();
}

static void serialize_data(lua_State *L, int current_depth, int max_depth, SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder &builder) {
  // Check depth to prevent stack overflow
  if (current_depth > max_depth) {
    luaL_error(L, "maximum nesting depth exceeded (limit: %d)", max_depth);
  }

  switch (lua_type(L, -1)) {
    case LUA_TSTRING: {
      serialize_append_string(L, builder, -1);
    } break;
    case LUA_TNUMBER: {
      serialize_append_number(L, builder, -1);
    } break;
    case LUA_TBOOLEAN: {
      serialize_append_bool(L, builder, -1);
    } break;
    case LUA_TTABLE: {
      current_depth++;
      int array_size = get_table_array_size(L);
      if (array_size > 0) {
        // Handle as array
        serialize_append_array(L, builder, -1, array_size, current_depth, max_depth);
      } else {
        // Handle as object
        serialize_append_object(L, builder, current_depth, max_depth);
      }
    } break;
    case LUA_TNIL: {
      // Treat Lua nil as JSON null
      builder.append_null();
    } break;
    case LUA_TLIGHTUSERDATA: {
      // Treat lightuserdata NULL as JSON null
      if (lua_touserdata(L, -1) == NULL) {
        builder.append_null();
      } else {
        luaL_error(L, "unsupported lightuserdata value for serialization");
      }
    } break;
    default: {
      const char *type_name = lua_typename(L, lua_type(L, -1));
      luaL_error(L, "unsupported Lua data type for serialization: %s", type_name);
    }
  }
};

// encode Lua data types into JSON string
static int encode(lua_State *L) {
  // the output string once the building is done.
  std::string_view json;

  int num_args = lua_gettop(L);
  luaL_argcheck(L, num_args >= 1 && num_args <= 2, num_args, "expected 1 or 2 arguments");

  // Get max_depth and buffer_size from options table if provided, otherwise use global settings
  int max_depth = get_max_depth(L);
  size_t desired_buffer_size = get_encode_buffer_size(L);

  if (num_args == 2) {
    luaL_checktype(L, 2, LUA_TTABLE);

    // Check for maxDepth in options table
    lua_getfield(L, 2, "maxDepth");
    if (!lua_isnil(L, -1)) {
      if (!lua_isnumber(L, -1)) {
        return luaL_error(L, "maxDepth option must be a number");
      }
      max_depth = lua_tointeger(L, -1);
      if (max_depth < 1) {
        return luaL_error(L, "maxDepth must be at least 1");
      }
    }
    lua_pop(L, 1);

    // Check for buffer_size in options table
    lua_getfield(L, 2, "buffer_size");
    if (!lua_isnil(L, -1)) {
      if (!lua_isnumber(L, -1)) {
        return luaL_error(L, "buffer_size option must be a number");
      }
      int buffer_size = lua_tointeger(L, -1);
      if (buffer_size < 1) {
        return luaL_error(L, "buffer_size must be at least 1");
      }
      if ((size_t)buffer_size > DEFAULT_MAX_ENCODE_BUFFER_SIZE) {
        return luaL_error(L, "buffer_size must not exceed %zu", (size_t)DEFAULT_MAX_ENCODE_BUFFER_SIZE);
      }
      desired_buffer_size = buffer_size;
    }
    lua_pop(L, 1);

    lua_pop(L, 1); // Remove options table, leaving data on top
  }

  // Get desired buffer size and recreate buffer if size changed
  if (encode_buffer == nullptr || encode_buffer_size != desired_buffer_size) {
    if (encode_buffer != nullptr) {
      delete encode_buffer;
    }
    encode_buffer = new SIMDJSON_BUILTIN_IMPLEMENTATION::builder::string_builder(desired_buffer_size);
    encode_buffer_size = desired_buffer_size;
  }

  // Reuse buffer - clear it but retain capacity, this should mean successive calls
  // are efficient in most cases.
  encode_buffer->clear();

  serialize_data(L, 0, max_depth, *encode_buffer);
  auto v_err = encode_buffer->view().get(json);
  if (v_err) {
    return luaL_error(L, "failed to get JSON view from buffer: %s", simdjson::error_message(v_err));
  }

  // validate utf-8
  if (!encode_buffer->validate_unicode()) {
    return luaL_error(L, "encoded JSON contains invalid UTF-8 sequences");
  }

  lua_pushlstring(L, json.data(), json.size());
  return 1;
};

// Set maximum nesting depth for encoding
static int setMaxEncodeDepth(lua_State *L) {
  int max_depth = luaL_checkinteger(L, 1);
  if (max_depth < 1) {
    return luaL_error(L, "Maximum encode depth must be at least 1");
  }
  set_max_depth(L, max_depth);
  return 0;
}

// Get current maximum nesting depth for encoding
static int getMaxEncodeDepth(lua_State *L) {
  lua_pushinteger(L, get_max_depth(L));
  return 1;
}

// Set encode buffer initial capacity in bytes
static int setEncodeBufferSize(lua_State *L) {
  int buffer_size = luaL_checkinteger(L, 1);
  if (buffer_size < 1) {
    return luaL_error(L, "Encode buffer size must be at least 1");
  }
  if ((size_t)buffer_size > DEFAULT_MAX_ENCODE_BUFFER_SIZE) {
    return luaL_error(L, "Encode buffer size must not exceed %zu", (size_t)DEFAULT_MAX_ENCODE_BUFFER_SIZE);
  }
  set_encode_buffer_size(L, buffer_size);
  return 0;
}

// Get encode buffer initial capacity in bytes
static int getEncodeBufferSize(lua_State *L) {
  lua_pushinteger(L, get_encode_buffer_size(L));
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
  ParsedObject(const char *json_file) : json_string(padded_string::load(json_file)), parser(new ondemand::parser{}) {
    this->doc = this->parser.get()->iterate(json_string);
  }
  ParsedObject(const char *json_str, size_t json_str_len) : json_string(json_str, json_str_len), parser(new ondemand::parser{}) {
    this->doc = this->parser.get()->iterate(json_string);
  }
  ~ParsedObject() {
  }
  ondemand::document *get_doc() {
    return &(this->doc);
  }
};

static int ParsedObject_delete(lua_State *L) {
  delete *reinterpret_cast<ParsedObject **>(lua_touserdata(L, 1));
  return 0;
}

static int ParsedObject_open(lua_State *L) {
  size_t json_str_len;
  const char *json_str = luaL_checklstring(L, 1, &json_str_len);

  try {
    ParsedObject **parsedObject = (ParsedObject **)(lua_newuserdata(L, sizeof(ParsedObject *)));
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

  try {
    ParsedObject **parsedObject = (ParsedObject **)(lua_newuserdata(L, sizeof(ParsedObject *)));
    *parsedObject = new ParsedObject(json_file);
    luaL_getmetatable(L, LUA_MYOBJECT);
    lua_setmetatable(L, -2);
  } catch (simdjson::simdjson_error &error) {
    luaL_error(L, error.what());
  }

  return 1;
}

static int ParsedObject_atPointer(lua_State *L) {
  ondemand::document *document = (*reinterpret_cast<ParsedObject **>(luaL_checkudata(L, 1, LUA_MYOBJECT)))->get_doc();
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
  luaL_error(L, "This should be treated as a read-only table. We may one day "
                "add array "
                "access for the elements, and it'll likely not be modifiable.");
  return 1;
}

static const struct luaL_Reg arraylib_m[] = {
    {"at", ParsedObject_atPointer}, {"atPointer", ParsedObject_atPointer}, {"__newindex", ParsedObject_newindex}, {"__gc", ParsedObject_delete}, {NULL, NULL}};

int luaopen_simdjson(lua_State *L) {
  luaL_newmetatable(L, LUA_MYOBJECT);
  lua_pushvalue(L, -1); /* duplicates the metatable */
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, arraylib_m, 0);

  // luaL_newlib(L, luasimdjson);

  lua_newtable(L);
  luaL_setfuncs(L, luasimdjson, 0);

  lua_pushlightuserdata(L, NULL);
  lua_setfield(L, -2, "null");

  lua_pushliteral(L, LUA_SIMDJSON_NAME);
  lua_setfield(L, -2, "_NAME");
  lua_pushliteral(L, LUA_SIMDJSON_VERSION);
  lua_setfield(L, -2, "_VERSION");

  return 1;
}
