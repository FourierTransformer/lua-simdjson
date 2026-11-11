#include "lua_encoder.h"

#include <climits>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <string_view>

#include "simdjson.h"

#define LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY "simdjson.maxEncodeDepth"
#define LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY "simdjson.encodeBufferSize"
#define DEFAULT_MAX_ENCODE_DEPTH 128
#define MAX_ENCODE_DEPTH 128
#define DEFAULT_ENCODE_BUFFER_SIZE (16 * 1024)
#define MAX_ENCODE_BUFFER_SIZE (64 * 1024 * 1024)

namespace
{
thread_local std::unique_ptr<simdjson::builder::string_builder> encode_buffer;
thread_local size_t encode_buffer_size = 0;

// Serialization failures are reported as plain data and raised as Lua errors
// by encode() only after every C++ serializer frame has returned. A Lua error
// is a longjmp, and on MSVC a longjmp unwinds through the C++ frames it skips
// using their compiler-generated unwind state. With simdjson's inlined
// noexcept builder code in those frames that unwind reached terminate()
// (0xC0000409, issue #117). No serializer code calls luaL_error.
enum class encode_status
{
  ok,
  non_finite_number,
  cyclic_table,
  depth_exceeded,
  unsupported_key_type,
  unsupported_value_type,
  unsupported_lightuserdata,
  allocation_failed,
  builder_error,
  invalid_utf8,
};

struct encode_context
{
  simdjson::builder::string_builder &builder;
  int max_depth;
  const void *active_tables[MAX_ENCODE_DEPTH];
  int active_table_count;
  encode_status status = encode_status::ok;
  int detail = 0; // Lua type tag or depth limit, depending on status
};

static bool fail(encode_context &context, encode_status status, int detail = 0)
{
  context.status = status;
  context.detail = detail;
  return false;
}

static int absolute_index(lua_State *L, int index)
{
  if (index > 0 || index <= LUA_REGISTRYINDEX)
  {
    return index;
  }
  return lua_gettop(L) + index + 1;
}

static lua_Integer check_integer(lua_State *L, int index, const char *name,
                                 lua_Integer maximum)
{
  if (lua_type(L, index) != LUA_TNUMBER)
  {
    luaL_error(L, "%s must be an integer", name);
  }

  lua_Number number = lua_tonumber(L, index);
  if (!std::isfinite(number) || std::floor(number) != number || number < 1 ||
      number > static_cast<lua_Number>(maximum))
  {
    luaL_error(L, "%s must be an integer between 1 and %lld", name,
               static_cast<long long>(maximum));
  }
  return static_cast<lua_Integer>(number);
}

static int check_encode_depth(lua_State *L, int index, const char *name)
{
  return static_cast<int>(check_integer(L, index, name, MAX_ENCODE_DEPTH));
}

static size_t check_encode_buffer_size(lua_State *L, int index,
                                       const char *name)
{
  return static_cast<size_t>(
      check_integer(L, index, name, MAX_ENCODE_BUFFER_SIZE));
}

static bool is_known_option(lua_State *L, int index)
{
  size_t length = 0;
  const char *key = lua_tolstring(L, index, &length);
  return (length == sizeof("maxDepth") - 1 &&
          std::memcmp(key, "maxDepth", length) == 0) ||
         (length == sizeof("bufferSize") - 1 &&
          std::memcmp(key, "bufferSize", length) == 0);
}

static void validate_encode_options(lua_State *L, int table_index)
{
  table_index = absolute_index(L, table_index);
  lua_pushnil(L);
  while (lua_next(L, table_index) != 0)
  {
    if (lua_type(L, -2) != LUA_TSTRING || !is_known_option(L, -2))
    {
      luaL_error(L, "unknown encode option");
    }
    lua_pop(L, 1);
  }
}

static void raw_get_field(lua_State *L, int table_index, const char *key)
{
  lua_pushstring(L, key);
  lua_rawget(L, absolute_index(L, table_index));
}

static void parse_encode_options(lua_State *L, int table_index, int &max_depth,
                                 size_t &desired_buffer_size)
{
  table_index = absolute_index(L, table_index);
  validate_encode_options(L, table_index);

  raw_get_field(L, table_index, "maxDepth");
  if (!lua_isnil(L, -1))
  {
    max_depth = check_encode_depth(L, -1, "maxDepth");
  }
  lua_pop(L, 1);

  raw_get_field(L, table_index, "bufferSize");
  if (!lua_isnil(L, -1))
  {
    desired_buffer_size =
        check_encode_buffer_size(L, -1, "bufferSize");
  }
  lua_pop(L, 1);
}

static int read_max_encode_depth(lua_State *L)
{
  lua_pushstring(L, LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  int max_depth = DEFAULT_MAX_ENCODE_DEPTH;
  if (lua_type(L, -1) == LUA_TNUMBER)
  {
    lua_Number value = lua_tonumber(L, -1);
    if (std::isfinite(value) && std::floor(value) == value && value >= 1 &&
        value <= MAX_ENCODE_DEPTH)
    {
      max_depth = static_cast<int>(value);
    }
  }
  lua_pop(L, 1);
  return max_depth;
}

static void write_max_encode_depth(lua_State *L, int max_depth)
{
  lua_pushstring(L, LUA_SIMDJSON_MAX_ENCODE_DEPTH_KEY);
  lua_pushinteger(L, max_depth);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static size_t read_encode_buffer_size(lua_State *L)
{
  lua_pushstring(L, LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  size_t buffer_size = DEFAULT_ENCODE_BUFFER_SIZE;
  if (lua_type(L, -1) == LUA_TNUMBER)
  {
    lua_Number value = lua_tonumber(L, -1);
    if (std::isfinite(value) && std::floor(value) == value && value >= 1 &&
        value <= MAX_ENCODE_BUFFER_SIZE)
    {
      buffer_size = static_cast<size_t>(value);
    }
  }
  lua_pop(L, 1);
  return buffer_size;
}

static void write_encode_buffer_size(lua_State *L, size_t buffer_size)
{
  lua_pushstring(L, LUA_SIMDJSON_ENCODE_BUFFER_SIZE_KEY);
  lua_pushinteger(L, static_cast<lua_Integer>(buffer_size));
  lua_rawset(L, LUA_REGISTRYINDEX);
}

// Return the array length for a dense 1..n table, or -1 for an object.
// The raw sequence length lets non-array tables with no sequence part be
// rejected after inspecting only their first entry. Tables that may be arrays
// are traversed once to verify that they contain exactly the keys 1..n.
static int get_table_array_size(lua_State *L, int table_index)
{
  table_index = absolute_index(L, table_index);

  size_t raw_length;
#if LUA_VERSION_NUM >= 502
  raw_length = lua_rawlen(L, table_index);
#else
  raw_length = lua_objlen(L, table_index);
#endif

  // The function and encoder array indexes use int, so larger tables retain
  // the existing object encoding behavior rather than narrowing the length.
  if (raw_length > static_cast<size_t>(INT_MAX))
  {
    return -1;
  }
  int hint = static_cast<int>(raw_length);

  if (hint == 0)
  {
    // A zero raw length means the table is empty or cannot be a dense array.
    // Inspecting the first entry distinguishes those cases without traversing
    // the entire object.
    lua_pushnil(L);
    if (lua_next(L, table_index) == 0)
    {
      // Empty tables are encoded as objects by serialize_table().
      return 0;
    }
    lua_pop(L, 2);
    // Non-empty with no sequence keys — it's an object.
    return -1;
  }

  // Verify that the table contains exactly hint numeric keys in the range
  // 1..hint, with no object keys or holes.
  int entry_count = 0;
  lua_pushnil(L);
  while (lua_next(L, table_index) != 0)
  {
    if (lua_type(L, -2) != LUA_TNUMBER)
    {
      lua_pop(L, 2);
      return -1;
    }

    lua_Number key = lua_tonumber(L, -2);
    if (!std::isfinite(key) || std::floor(key) != key || key < 1 ||
        key > static_cast<lua_Number>(hint))
    {
      // Key is out of the expected 1..hint range — not a pure sequence.
      lua_pop(L, 2);
      return -1;
    }

    entry_count++;
    lua_pop(L, 1);
  }

  // If entry_count == hint, every slot 1..hint is filled with no extras.
  return entry_count == hint ? hint : -1;
}

static bool serialize_data(lua_State *L, int value_index,
                           encode_context &context);

static bool serialize_append_number(lua_State *L, int index,
                                    encode_context &context)
{
#if LUA_VERSION_NUM >= 503
  if (lua_isinteger(L, index))
  {
    context.builder.append(lua_tointeger(L, index));
    return true;
  }
#endif
  lua_Number value = lua_tonumber(L, index);
  if (!std::isfinite(value))
  {
    return fail(context, encode_status::non_finite_number);
  }
  context.builder.append(value);
  return true;
}

static void serialize_append_string(lua_State *L, int index,
                                    encode_context &context)
{
  size_t length = 0;
  const char *value = lua_tolstring(L, index, &length);
  context.builder.escape_and_append_with_quotes(
      std::string_view(value, length));
}

static bool enter_table(lua_State *L, int table_index,
                        encode_context &context)
{
  const void *identity = lua_topointer(L, table_index);
  for (int i = 0; i < context.active_table_count; i++)
  {
    if (context.active_tables[i] == identity)
    {
      return fail(context, encode_status::cyclic_table);
    }
  }
  if (context.active_table_count >= context.max_depth)
  {
    return fail(context, encode_status::depth_exceeded, context.max_depth);
  }
  context.active_tables[context.active_table_count++] = identity;
  return true;
}

static bool serialize_append_array(lua_State *L, int table_index,
                                   int array_size, encode_context &context)
{
  table_index = absolute_index(L, table_index);
  context.builder.start_array();
  for (int i = 1; i <= array_size; i++)
  {
    if (i > 1)
    {
      context.builder.append_comma();
    }
    lua_rawgeti(L, table_index, i);
    if (!serialize_data(L, -1, context))
    {
      return false;
    }
    lua_pop(L, 1);
  }
  context.builder.end_array();
  return true;
}

static bool serialize_append_object(lua_State *L, int table_index,
                                    encode_context &context)
{
  table_index = absolute_index(L, table_index);
  context.builder.start_object();
  bool first = true;
  lua_pushnil(L);

  while (lua_next(L, table_index) != 0)
  {
    if (!first)
    {
      context.builder.append_comma();
    }
    first = false;

    int key_type = lua_type(L, -2);
    if (key_type == LUA_TSTRING)
    {
      serialize_append_string(L, -2, context);
    }
    else if (key_type == LUA_TNUMBER)
    {
      context.builder.append('"');
      if (!serialize_append_number(L, -2, context))
      {
        return false;
      }
      context.builder.append('"');
    }
    else
    {
      return fail(context, encode_status::unsupported_key_type, key_type);
    }

    context.builder.append_colon();
    if (!serialize_data(L, -1, context))
    {
      return false;
    }
    lua_pop(L, 1);
  }
  context.builder.end_object();
  return true;
}

static bool serialize_data(lua_State *L, int value_index,
                           encode_context &context)
{
  value_index = absolute_index(L, value_index);
  int value_type = lua_type(L, value_index);
  switch (value_type)
  {
  case LUA_TSTRING:
    serialize_append_string(L, value_index, context);
    return true;
  case LUA_TNUMBER:
    return serialize_append_number(L, value_index, context);
  case LUA_TBOOLEAN:
    context.builder.append(lua_toboolean(L, value_index) != 0);
    return true;
  case LUA_TTABLE:
  {
    if (!enter_table(L, value_index, context))
    {
      return false;
    }
    int array_size = get_table_array_size(L, value_index);
    bool serialized =
        array_size > 0
            ? serialize_append_array(L, value_index, array_size, context)
            : serialize_append_object(L, value_index, context);
    if (!serialized)
    {
      return false;
    }
    context.active_table_count--;
    return true;
  }
  case LUA_TNIL:
    context.builder.append_null();
    return true;
  case LUA_TLIGHTUSERDATA:
    if (lua_touserdata(L, value_index) == NULL)
    {
      context.builder.append_null();
      return true;
    }
    return fail(context, encode_status::unsupported_lightuserdata);
  default:
    return fail(context, encode_status::unsupported_value_type, value_type);
  }
}

// Everything that touches the builder runs here and returns plain data. The
// noinline attribute keeps this body out of encode(), whose frame must stay
// free of C++ unwind state because it is the one place that raises Lua errors.
#if defined(_MSC_VER)
#define LUA_SIMDJSON_NOINLINE __declspec(noinline)
#else
#define LUA_SIMDJSON_NOINLINE __attribute__((noinline))
#endif

struct encode_outcome
{
  encode_status status;
  int detail;
  const char *text; // JSON bytes (ok) or a static simdjson error message
  size_t length;
};

static LUA_SIMDJSON_NOINLINE encode_outcome
encode_value(lua_State *L, int max_depth, size_t desired_buffer_size)
{
  if (!encode_buffer || encode_buffer_size != desired_buffer_size)
  {
    auto *replacement = new (std::nothrow)
        simdjson::builder::string_builder(desired_buffer_size);
    if (replacement == nullptr)
    {
      return {encode_status::allocation_failed, 0, nullptr, 0};
    }
    encode_buffer.reset(replacement);
    encode_buffer_size = desired_buffer_size;
  }

  encode_buffer->clear();
  encode_context context{*encode_buffer, max_depth, {}, 0};
  if (!serialize_data(L, 1, context))
  {
    return {context.status, context.detail, nullptr, 0};
  }

  std::string_view json;
  auto error = encode_buffer->view().get(json);
  if (error)
  {
    return {encode_status::builder_error, 0, simdjson::error_message(error), 0};
  }
  if (!encode_buffer->validate_unicode())
  {
    return {encode_status::invalid_utf8, 0, nullptr, 0};
  }
  return {encode_status::ok, 0, json.data(), json.size()};
}
} // namespace

int encode(lua_State *L)
{
  int argument_count = lua_gettop(L);
  luaL_argcheck(L, argument_count >= 1 && argument_count <= 2, 1,
                "expected 1 or 2 arguments");

  int max_depth = read_max_encode_depth(L);
  size_t desired_buffer_size = read_encode_buffer_size(L);
  if (argument_count == 2)
  {
    luaL_checktype(L, 2, LUA_TTABLE);
    parse_encode_options(L, 2, max_depth, desired_buffer_size);
  }

  // No C++ object with a destructor lives in this frame, so raising a Lua
  // error (longjmp) below has no C++ unwind state to trip over.
  encode_outcome outcome = encode_value(L, max_depth, desired_buffer_size);
  switch (outcome.status)
  {
  case encode_status::ok:
    lua_pushlstring(L, outcome.text, outcome.length);
    return 1;
  case encode_status::non_finite_number:
    return luaL_error(L, "cannot encode NaN or infinity as JSON");
  case encode_status::cyclic_table:
    return luaL_error(L, "cannot encode a cyclic table");
  case encode_status::depth_exceeded:
    return luaL_error(L, "maximum nesting depth exceeded (limit: %d)",
                      outcome.detail);
  case encode_status::unsupported_key_type:
    return luaL_error(L, "unsupported key type in table for serialization: %s",
                      lua_typename(L, outcome.detail));
  case encode_status::unsupported_value_type:
    return luaL_error(L, "unsupported Lua data type for serialization: %s",
                      lua_typename(L, outcome.detail));
  case encode_status::unsupported_lightuserdata:
    return luaL_error(L, "unsupported lightuserdata value for serialization");
  case encode_status::allocation_failed:
    return luaL_error(L, "failed to allocate JSON encoder");
  case encode_status::builder_error:
    return luaL_error(L, "failed to build JSON: %s", outcome.text);
  case encode_status::invalid_utf8:
    return luaL_error(L, "encoded JSON contains invalid UTF-8 sequences");
  }
  return luaL_error(L, "unknown encoder failure");
}

int set_max_encode_depth(lua_State *L)
{
  int max_depth = check_encode_depth(L, 1, "maximum encode depth");
  write_max_encode_depth(L, max_depth);
  return 0;
}

int get_max_encode_depth(lua_State *L)
{
  lua_pushinteger(L, read_max_encode_depth(L));
  return 1;
}

int set_encode_buffer_size(lua_State *L)
{
  size_t buffer_size =
      check_encode_buffer_size(L, 1, "encode buffer size");
  write_encode_buffer_size(L, buffer_size);
  return 0;
}

int get_encode_buffer_size(lua_State *L)
{
  lua_pushinteger(L,
                  static_cast<lua_Integer>(read_encode_buffer_size(L)));
  return 1;
}
