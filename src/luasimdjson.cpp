#include <cmath>
#include <cstring>
#include <limits>
// clang-format off
#include <lua.hpp>
#include <lauxlib.h>
// clang-format on
#include <memory>
#include <new>

#define NDEBUG
#define __OPTIMIZE__ 1

// clang-format off
#include "simdjson.h"
#include "luasimdjson.h"
// clang-format on

#define LUA_SIMDJSON_NAME "simdjson"
#define LUA_SIMDJSON_VERSION "1.0.1"
#define LUA_SIMDJSON_MAX_DECODE_DEPTH_KEY "simdjson.maxDecodeDepth"
#define LUA_SIMDJSON_DECODE_BUFFER_SIZE_KEY "simdjson.decodeBufferSize"
#define LUA_SIMDJSON_DECODE_LEASE_META "simdjson.decode_vm_lease"
#define LUA_SIMDJSON_FALLBACK_STATE_META "simdjson.fallback_decode_state"
#define DEFAULT_MAX_DECODE_DEPTH static_cast<int>(simdjson::DEFAULT_MAX_DEPTH)
#define MAX_DECODE_DEPTH static_cast<int>(simdjson::DEFAULT_MAX_DEPTH)
#define DEFAULT_DECODE_BUFFER_SIZE (16 * 1024)
#define MAX_DECODE_BUFFER_SIZE (64 * 1024 * 1024)
#define DECODE_STACK_SLOTS_PER_TABLE 4

#if defined(_MSC_VER)
#define LUA_SIMDJSON_NOINLINE __declspec(noinline)
#else
#define LUA_SIMDJSON_NOINLINE __attribute__((noinline))
#endif

using namespace simdjson;

enum class decode_status {
  ok,
  simdjson_error,
  unknown_json_type,
  depth_exceeded,
  stack_overflow,
  input_too_large,
  allocation_failed,
  object_in_use,
};

struct decode_outcome {
  decode_status status;
  simdjson::error_code error;
  int detail;
};

struct decode_context {
  int max_depth;
  int current_depth = 0;
  decode_status status = decode_status::ok;
  simdjson::error_code error = simdjson::SUCCESS;
  int detail = 0;
};

static bool fail_status(decode_context &context, decode_status status,
                        int detail = 0) {
  context.status = status;
  context.detail = detail;
  return false;
}

static bool fail_simdjson(decode_context &context, simdjson::error_code error) {
  context.status = decode_status::simdjson_error;
  context.error = error;
  return false;
}

static int raise_decode_error(lua_State *L, const decode_outcome &outcome) {
  switch (outcome.status) {
  case decode_status::ok:
    return 1;
  case decode_status::simdjson_error:
    return luaL_error(L, "%s", simdjson::error_message(outcome.error));
  case decode_status::unknown_json_type:
    return luaL_error(L, "simdjson::ondemand::json_type::unknown or "
                         "unsupported type encountered");
  case decode_status::depth_exceeded:
    return luaL_error(L, "maximum nesting depth exceeded (limit: %d)",
                      outcome.detail);
  case decode_status::stack_overflow:
    return luaL_error(L, "cannot decode: Lua stack overflow");
  case decode_status::input_too_large:
    return luaL_error(L, "JSON input is too large");
  case decode_status::allocation_failed:
    return luaL_error(L, "failed to allocate JSON parse buffer");
  case decode_status::object_in_use:
    return luaL_error(L, "ParsedObject is already being traversed");
  }
  return luaL_error(L, "unknown decoder failure");
}

#if !defined(luaL_newlibtable) &&                                              \
    (!defined LUA_VERSION_NUM || LUA_VERSION_NUM <= 501)
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

static int decode_vm_lease_key_anchor = 0;
static int decode_active_thread_key_anchor = 0;

struct decode_vm_lease {
  lua_State *active_thread;
  bool finalized;
};

struct reusable_decode_state {
  ondemand::parser parser;
  std::unique_ptr<char[]> parse_buffer;
  size_t parse_buffer_capacity = 0;
  simdjson::padded_string file_parse_buffer;
  bool in_use = false;
  decode_vm_lease *owner_vm = nullptr;
};

thread_local reusable_decode_state tls_decode_state;

static int decode_vm_lease_gc(lua_State *L) {
  decode_vm_lease *vm_lease =
      reinterpret_cast<decode_vm_lease *>(lua_touserdata(L, 1));
  if (vm_lease != nullptr) {
    vm_lease->finalized = true;
    vm_lease->active_thread = nullptr;
    if (tls_decode_state.owner_vm == vm_lease) {
      tls_decode_state.in_use = false;
      tls_decode_state.owner_vm = nullptr;
    }
  }
  return 0;
}

static int fallback_decode_state_gc(lua_State *L) {
  reusable_decode_state **slot =
      reinterpret_cast<reusable_decode_state **>(lua_touserdata(L, 1));
  if (slot != nullptr && *slot != nullptr) {
    delete *slot;
    *slot = nullptr;
  }
  return 0;
}

static decode_vm_lease *ensure_decode_vm_lease(lua_State *L) {
  lua_pushlightuserdata(L, &decode_vm_lease_key_anchor);
  lua_rawget(L, LUA_REGISTRYINDEX);
  decode_vm_lease *vm_lease =
      reinterpret_cast<decode_vm_lease *>(lua_touserdata(L, -1));
  lua_pop(L, 1);
  if (vm_lease != nullptr) {
    return vm_lease;
  }

  lua_pushlightuserdata(L, &decode_active_thread_key_anchor);
  lua_pushboolean(L, 0);
  lua_rawset(L, LUA_REGISTRYINDEX);

  luaL_newmetatable(L, LUA_SIMDJSON_FALLBACK_STATE_META);
  lua_pushcfunction(L, fallback_decode_state_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  vm_lease = reinterpret_cast<decode_vm_lease *>(
      lua_newuserdata(L, sizeof(decode_vm_lease)));
  vm_lease->active_thread = nullptr;
  vm_lease->finalized = false;
  luaL_newmetatable(L, LUA_SIMDJSON_DECODE_LEASE_META);
  lua_pushcfunction(L, decode_vm_lease_gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);

  lua_pushlightuserdata(L, &decode_vm_lease_key_anchor);
  lua_pushvalue(L, -2);
  lua_rawset(L, LUA_REGISTRYINDEX);
  lua_pop(L, 1);
  return vm_lease;
}

static void write_active_decode_thread(decode_vm_lease *vm_lease, lua_State *L,
                                       bool active) {
  if (vm_lease == nullptr) {
    return;
  }
  if (!active) {
    vm_lease->active_thread = nullptr;
    if (L == nullptr || lua_status(L) != 0 || !lua_checkstack(L, 2)) {
      return;
    }
    lua_pushlightuserdata(L, &decode_active_thread_key_anchor);
    lua_pushboolean(L, 0);
    lua_rawset(L, LUA_REGISTRYINDEX);
    return;
  }
  if (L == nullptr || !lua_checkstack(L, 2)) {
    return;
  }
  lua_pushlightuserdata(L, &decode_active_thread_key_anchor);
  lua_pushthread(L);
  vm_lease->active_thread = L;
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static bool is_decode_active_on_call_stack(lua_State *L, int start_level) {
  if (L == nullptr || lua_status(L) != 0) {
    return false;
  }
  lua_Debug ar;
  for (int level = start_level; lua_getstack(L, level, &ar) != 0; ++level) {
    if (!lua_checkstack(L, 1)) {
      return true;
    }
    if (lua_getinfo(L, "f", &ar) != 0) {
      lua_CFunction fn = lua_tocfunction(L, -1);
      lua_pop(L, 1);
      if (fn == parse || fn == parse_file) {
        return true;
      }
    }
  }
  return false;
}

struct decode_state_lease {
  reusable_decode_state *state;
  reusable_decode_state **fallback_slot;
  decode_vm_lease *owner_vm;
  lua_State *lease_thread;
  int fallback_index;
  bool using_tls;

  decode_state_lease(lua_State *L, decode_vm_lease *vm_lease) {
    lua_State *prev_thread =
        (tls_decode_state.in_use && tls_decode_state.owner_vm != nullptr)
            ? tls_decode_state.owner_vm->active_thread
            : nullptr;
    int start_level = (prev_thread == L) ? 1 : 0;
    bool can_use_tls =
        (vm_lease != nullptr && !vm_lease->finalized) &&
        (!tls_decode_state.in_use ||
         !is_decode_active_on_call_stack(prev_thread, start_level));
    if (can_use_tls) {
      if (tls_decode_state.owner_vm != nullptr &&
          tls_decode_state.owner_vm != vm_lease &&
          tls_decode_state.owner_vm->active_thread != nullptr) {
        write_active_decode_thread(tls_decode_state.owner_vm,
                                   tls_decode_state.owner_vm->active_thread,
                                   false);
      }
      write_active_decode_thread(vm_lease, L, true);
      tls_decode_state.in_use = true;
      tls_decode_state.owner_vm = vm_lease;
      state = &tls_decode_state;
      fallback_slot = nullptr;
      owner_vm = vm_lease;
      lease_thread = L;
      fallback_index = 0;
      using_tls = true;
    } else {
      reusable_decode_state **slot = reinterpret_cast<reusable_decode_state **>(
          lua_newuserdata(L, sizeof(reusable_decode_state *)));
      *slot = nullptr;
      luaL_getmetatable(L, LUA_SIMDJSON_FALLBACK_STATE_META);
      lua_setmetatable(L, -2);
      fallback_index = lua_gettop(L);
      *slot = new (std::nothrow) reusable_decode_state();
      state = *slot;
      fallback_slot = slot;
      owner_vm = nullptr;
      lease_thread = L;
      using_tls = false;
    }
  }

  ~decode_state_lease() {
    if (using_tls) {
      write_active_decode_thread(owner_vm, lease_thread, false);
      tls_decode_state.in_use = false;
      tls_decode_state.owner_vm = nullptr;
    } else if (fallback_slot != nullptr) {
      delete *fallback_slot;
      *fallback_slot = nullptr;
      if (lease_thread != nullptr && fallback_index > 0 &&
          lua_gettop(lease_thread) >= fallback_index) {
        lua_remove(lease_thread, fallback_index);
      }
    }
  }
};

static void shrink_decode_buffers(reusable_decode_state &state,
                                  size_t desired_buffer_size) noexcept {
  state.file_parse_buffer = simdjson::padded_string();
  size_t max_retained = desired_buffer_size + SIMDJSON_PADDING;
  if (state.parse_buffer_capacity > max_retained) {
    state.parse_buffer.reset();
    state.parse_buffer_capacity = 0;
  }
  if (state.parser.capacity() > desired_buffer_size) {
    state.parser = ondemand::parser{};
  }
}

static simdjson::error_code
ensure_ondemand_parser_ready(ondemand::parser &parser, size_t doc_len,
                             size_t desired_buffer_size,
                             int max_depth) noexcept {
  size_t target_capacity =
      doc_len > desired_buffer_size ? doc_len : desired_buffer_size;
  size_t target_depth = static_cast<size_t>(max_depth);
  if (parser.capacity() < target_capacity ||
      parser.max_depth() < target_depth) {
    return parser.allocate(target_capacity, target_depth);
  }
  return simdjson::SUCCESS;
}

static int absolute_index(lua_State *L, int index) {
  if (index > 0 || index <= LUA_REGISTRYINDEX) {
    return index;
  }
  return lua_gettop(L) + index + 1;
}

static lua_Integer check_integer(lua_State *L, int index, const char *name,
                                 lua_Integer maximum) {
  if (lua_type(L, index) != LUA_TNUMBER) {
    luaL_error(L, "%s must be an integer", name);
  }

  lua_Number number = lua_tonumber(L, index);
  if (!std::isfinite(number) || std::floor(number) != number || number < 1 ||
      number > static_cast<lua_Number>(maximum)) {
    luaL_error(L, "%s must be an integer between 1 and %d", name,
               static_cast<int>(maximum));
  }
  return static_cast<lua_Integer>(number);
}

static int check_decode_depth(lua_State *L, int index, const char *name) {
  return static_cast<int>(check_integer(L, index, name, MAX_DECODE_DEPTH));
}

static size_t check_decode_buffer_size(lua_State *L, int index,
                                       const char *name) {
  return static_cast<size_t>(
      check_integer(L, index, name, MAX_DECODE_BUFFER_SIZE));
}

static bool is_known_decode_option(lua_State *L, int index) {
  size_t length = 0;
  const char *key = lua_tolstring(L, index, &length);
  return (length == sizeof("maxDepth") - 1 &&
          std::memcmp(key, "maxDepth", length) == 0) ||
         (length == sizeof("bufferSize") - 1 &&
          std::memcmp(key, "bufferSize", length) == 0);
}

static void validate_decode_options(lua_State *L, int table_index) {
  table_index = absolute_index(L, table_index);
  lua_pushnil(L);
  while (lua_next(L, table_index) != 0) {
    if (lua_type(L, -2) != LUA_TSTRING || !is_known_decode_option(L, -2)) {
      luaL_error(L, "unknown decode option");
    }
    lua_pop(L, 1);
  }
}

static void raw_get_field(lua_State *L, int table_index, const char *key) {
  lua_pushstring(L, key);
  lua_rawget(L, absolute_index(L, table_index));
}

static void parse_decode_options(lua_State *L, int table_index, int &max_depth,
                                 size_t &desired_buffer_size) {
  table_index = absolute_index(L, table_index);
  validate_decode_options(L, table_index);

  raw_get_field(L, table_index, "maxDepth");
  if (!lua_isnil(L, -1)) {
    max_depth = check_decode_depth(L, -1, "maxDepth");
  }
  lua_pop(L, 1);

  raw_get_field(L, table_index, "bufferSize");
  if (!lua_isnil(L, -1)) {
    desired_buffer_size = check_decode_buffer_size(L, -1, "bufferSize");
  }
  lua_pop(L, 1);
}

static int read_max_decode_depth(lua_State *L) {
  lua_pushstring(L, LUA_SIMDJSON_MAX_DECODE_DEPTH_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  int max_depth = DEFAULT_MAX_DECODE_DEPTH;
  if (lua_type(L, -1) == LUA_TNUMBER) {
    lua_Number value = lua_tonumber(L, -1);
    if (std::isfinite(value) && std::floor(value) == value && value >= 1 &&
        value <= MAX_DECODE_DEPTH) {
      max_depth = static_cast<int>(value);
    }
  }
  lua_pop(L, 1);
  return max_depth;
}

static void write_max_decode_depth(lua_State *L, int max_depth) {
  lua_pushstring(L, LUA_SIMDJSON_MAX_DECODE_DEPTH_KEY);
  lua_pushinteger(L, max_depth);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static size_t read_decode_buffer_size(lua_State *L) {
  lua_pushstring(L, LUA_SIMDJSON_DECODE_BUFFER_SIZE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  size_t buffer_size = DEFAULT_DECODE_BUFFER_SIZE;
  if (lua_type(L, -1) == LUA_TNUMBER) {
    lua_Number value = lua_tonumber(L, -1);
    if (std::isfinite(value) && std::floor(value) == value && value >= 1 &&
        value <= MAX_DECODE_BUFFER_SIZE) {
      buffer_size = static_cast<size_t>(value);
    }
  }
  lua_pop(L, 1);
  return buffer_size;
}

static void write_decode_buffer_size(lua_State *L, size_t buffer_size) {
  lua_pushstring(L, LUA_SIMDJSON_DECODE_BUFFER_SIZE_KEY);
  lua_pushinteger(L, static_cast<lua_Integer>(buffer_size));
  lua_rawset(L, LUA_REGISTRYINDEX);
}

template <typename T>
static LUA_SIMDJSON_NOINLINE bool
convert_ondemand_scalar_to_table(lua_State *L, T &element,
                                 ondemand::json_type type,
                                 decode_context &context) {
  switch (type) {
  case ondemand::json_type::number: {
    ondemand::number number;
    if (auto error = element.get_number().get(number); error) {
      if (error == simdjson::BIGINT_ERROR) {
        double value = 0;
        if (auto dbl_error = element.get_double().get(value); dbl_error) {
          return fail_simdjson(context, dbl_error);
        }
        lua_pushnumber(L, value);
        return true;
      }
      return fail_simdjson(context, error);
    }
    ondemand::number_type number_type = number.get_number_type();
    switch (number_type) {
    case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::floating_point_number: {
      double value = 0;
      if (auto error = element.get_double().get(value); error) {
        return fail_simdjson(context, error);
      }
      lua_pushnumber(L, value);
      break;
    }

    case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::signed_integer: {
      int64_t value = 0;
      if (auto error = element.get_int64().get(value); error) {
        return fail_simdjson(context, error);
      }
#if defined(LUA_MAXINTEGER) && defined(LUA_MININTEGER)
      if (value < LUA_MININTEGER || value > LUA_MAXINTEGER) {
        lua_pushnumber(L, static_cast<lua_Number>(value));
      } else {
        lua_pushinteger(L, static_cast<lua_Integer>(value));
      }
#else
      lua_pushnumber(L, static_cast<lua_Number>(value));
#endif
      break;
    }

    case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::unsigned_integer: {
// a uint64 can be greater than an int64, so we must check how large and pass as
// a number if larger but LUA_MAXINTEGER (which is only defined in 5.3+)
#if defined(LUA_MAXINTEGER)
      uint64_t actual_value = 0;
      if (auto error = element.get_uint64().get(actual_value); error) {
        return fail_simdjson(context, error);
      }
      if (actual_value > LUA_MAXINTEGER) {
        lua_pushnumber(L, actual_value);
      } else {
        lua_pushinteger(L, actual_value);
      }
#else
      double value = 0;
      if (auto error = element.get_double().get(value); error) {
        return fail_simdjson(context, error);
      }
      lua_pushnumber(L, value);
#endif
      break;
    }

    case SIMDJSON_BUILTIN_IMPLEMENTATION::number_type::big_integer: {
      double value = 0;
      if (auto error = element.get_double().get(value); error) {
        return fail_simdjson(context, error);
      }
      lua_pushnumber(L, value);
      break;
    }
    }
    return true;
  }

  case ondemand::json_type::string: {
    std::string_view s;
    if (auto error = element.get_string().get(s); error) {
      return fail_simdjson(context, error);
    }
    lua_pushlstring(L, s.data(), s.size());
    return true;
  }

  case ondemand::json_type::boolean: {
    bool value = false;
    if (auto error = element.get_bool().get(value); error) {
      return fail_simdjson(context, error);
    }
    lua_pushboolean(L, value);
    return true;
  }

  case ondemand::json_type::null: {
    bool is_null = false;
    if (auto error = element.is_null().get(is_null); error) {
      return fail_simdjson(context, error);
    }
    if (!is_null) {
      return fail_simdjson(context, simdjson::INCORRECT_TYPE);
    }
    lua_pushlightuserdata(L, NULL);
    return true;
  }

  case ondemand::json_type::array:
  case ondemand::json_type::object:
  case ondemand::json_type::unknown:
  default:
    return fail_status(context, decode_status::unknown_json_type);
  }
}

static LUA_SIMDJSON_NOINLINE bool
push_object_field_key(lua_State *L,
                      simdjson_result<ondemand::field> &field_result,
                      ondemand::value &child, decode_context &context) {
  ondemand::field field;
  if (auto error = std::move(field_result).get(field); error) {
    return fail_simdjson(context, error);
  }
  std::string_view s;
  if (auto error = field.unescaped_key().get(s); error) {
    return fail_simdjson(context, error);
  }
  lua_pushlstring(L, s.data(), s.size());
  child = std::move(field).value();
  return true;
}

template <typename T>
static LUA_SIMDJSON_NOINLINE bool
prepare_element_type(T &element, ondemand::json_type &type,
                     decode_context &context) {
  if (auto error = element.type().get(type); error) {
    return fail_simdjson(context, error);
  }
  return true;
}

template <typename T>
static LUA_SIMDJSON_NOINLINE bool prepare_array(lua_State *L, T &element,
                                                ondemand::array &array,
                                                decode_context &context) {
  if (context.current_depth >= context.max_depth) {
    return fail_status(context, decode_status::depth_exceeded,
                       context.max_depth);
  }
  if (!lua_checkstack(L, DECODE_STACK_SLOTS_PER_TABLE)) {
    return fail_status(context, decode_status::stack_overflow);
  }
  if (auto error = element.get_array().get(array); error) {
    return fail_simdjson(context, error);
  }
  context.current_depth++;
  lua_newtable(L);
  return true;
}

template <typename T>
static LUA_SIMDJSON_NOINLINE bool prepare_object(lua_State *L, T &element,
                                                 ondemand::object &object,
                                                 decode_context &context) {
  if (context.current_depth >= context.max_depth) {
    return fail_status(context, decode_status::depth_exceeded,
                       context.max_depth);
  }
  if (!lua_checkstack(L, DECODE_STACK_SLOTS_PER_TABLE)) {
    return fail_status(context, decode_status::stack_overflow);
  }
  if (auto error = element.get_object().get(object); error) {
    return fail_simdjson(context, error);
  }
  context.current_depth++;
  lua_newtable(L);
  return true;
}

template <typename T>
static bool convert_ondemand_element_to_table(lua_State *L, T &element,
                                              decode_context &context) {
  static_assert(std::is_base_of<ondemand::document, T>::value ||
                    std::is_base_of<ondemand::value, T>::value,
                "type parameter must be document or value");

  ondemand::json_type type;
  if (!prepare_element_type(element, type, context)) {
    return false;
  }

  switch (type) {
  case ondemand::json_type::array: {
    ondemand::array array;
    if (!prepare_array(L, element, array, context)) {
      return false;
    }

    int count = 1;
    for (simdjson_result<ondemand::value> child_result : array) {
      ondemand::value child;
      if (auto error = child_result.get(child); error) {
        return fail_simdjson(context, error);
      }
      if (!convert_ondemand_element_to_table(L, child, context)) {
        return false;
      }
      lua_rawseti(L, -2, count++);
    }
    context.current_depth--;
    return true;
  }

  case ondemand::json_type::object: {
    ondemand::object object;
    if (!prepare_object(L, element, object, context)) {
      return false;
    }

    for (simdjson_result<ondemand::field> field_result : object) {
      ondemand::value child;
      if (!push_object_field_key(L, field_result, child, context)) {
        return false;
      }
      if (!convert_ondemand_element_to_table(L, child, context)) {
        return false;
      }
      lua_rawset(L, -3);
    }
    context.current_depth--;
    return true;
  }

  default:
    return convert_ondemand_scalar_to_table(L, element, type, context);
  }
}

static LUA_SIMDJSON_NOINLINE decode_outcome
parse_value(lua_State *L, decode_vm_lease *vm_lease, const char *json_str,
            size_t json_str_len, int max_depth, size_t desired_buffer_size) {
  decode_state_lease lease(L, vm_lease);
  if (lease.state == nullptr) {
    return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
  }
  reusable_decode_state &state = *lease.state;
  shrink_decode_buffers(state, desired_buffer_size);

  if (json_str_len > std::numeric_limits<size_t>::max() - SIMDJSON_PADDING) {
    return {decode_status::input_too_large, simdjson::SUCCESS, 0};
  }

  size_t base_capacity =
      json_str_len > desired_buffer_size ? json_str_len : desired_buffer_size;
  size_t required_capacity = base_capacity + SIMDJSON_PADDING;
  if (state.parse_buffer_capacity < required_capacity) {
    state.parse_buffer.reset();
    state.parse_buffer_capacity = 0;
    char *replacement = new (std::nothrow) char[required_capacity];
    if (replacement == nullptr) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }
    state.parse_buffer.reset(replacement);
    state.parse_buffer_capacity = required_capacity;
  }

  if (json_str_len > 0) {
    std::memcpy(state.parse_buffer.get(), json_str, json_str_len);
  }
  std::memset(state.parse_buffer.get() + json_str_len, 0, SIMDJSON_PADDING);
  simdjson::padded_string_view padded_view(
      state.parse_buffer.get(), json_str_len, state.parse_buffer_capacity);

  if (auto error = ensure_ondemand_parser_ready(state.parser, json_str_len,
                                                desired_buffer_size, max_depth);
      error) {
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, error, 0};
  }

  ondemand::document doc;
  if (auto error = state.parser.iterate(padded_view).get(doc); error) {
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, error, 0};
  }

  const int initial_top = lua_gettop(L);
  decode_context context{max_depth};
  if (!convert_ondemand_element_to_table(L, doc, context)) {
    lua_settop(L, initial_top);
    shrink_decode_buffers(state, desired_buffer_size);
    return {context.status, context.error, context.detail};
  }

  if (!doc.at_end()) {
    lua_settop(L, initial_top);
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, simdjson::TRAILING_CONTENT, 0};
  }

  shrink_decode_buffers(state, desired_buffer_size);
  return {decode_status::ok, simdjson::SUCCESS, 0};
}

static LUA_SIMDJSON_NOINLINE decode_outcome parse_file_value(
    lua_State *L, decode_vm_lease *vm_lease, const char *json_file,
    size_t json_file_len, int max_depth, size_t desired_buffer_size) {
  decode_state_lease lease(L, vm_lease);
  if (lease.state == nullptr) {
    return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
  }
  reusable_decode_state &state = *lease.state;
  shrink_decode_buffers(state, desired_buffer_size);

  if (std::memchr(json_file, '\0', json_file_len) != nullptr) {
    return {decode_status::simdjson_error, simdjson::IO_ERROR, 0};
  }

  if (auto error =
          simdjson::padded_string::load(json_file).get(state.file_parse_buffer);
      error) {
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, error, 0};
  }

  if (auto error = ensure_ondemand_parser_ready(state.parser,
                                                state.file_parse_buffer.size(),
                                                desired_buffer_size, max_depth);
      error) {
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, error, 0};
  }

  ondemand::document doc;
  if (auto error = state.parser.iterate(state.file_parse_buffer).get(doc);
      error) {
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, error, 0};
  }

  const int initial_top = lua_gettop(L);
  decode_context context{max_depth};
  if (!convert_ondemand_element_to_table(L, doc, context)) {
    lua_settop(L, initial_top);
    shrink_decode_buffers(state, desired_buffer_size);
    return {context.status, context.error, context.detail};
  }

  if (!doc.at_end()) {
    lua_settop(L, initial_top);
    shrink_decode_buffers(state, desired_buffer_size);
    return {decode_status::simdjson_error, simdjson::TRAILING_CONTENT, 0};
  }

  shrink_decode_buffers(state, desired_buffer_size);
  return {decode_status::ok, simdjson::SUCCESS, 0};
}

static int parse(lua_State *L) {
  int argument_count = lua_gettop(L);
  luaL_argcheck(L, argument_count >= 1 && argument_count <= 2, 1,
                "expected 1 or 2 arguments");
  size_t json_str_len = 0;
  const char *json_str = luaL_checklstring(L, 1, &json_str_len);

  int max_depth = read_max_decode_depth(L);
  size_t desired_buffer_size = read_decode_buffer_size(L);
  if (argument_count == 2) {
    luaL_checktype(L, 2, LUA_TTABLE);
    parse_decode_options(L, 2, max_depth, desired_buffer_size);
  }

  decode_vm_lease *vm_lease = ensure_decode_vm_lease(L);
  const int initial_top = lua_gettop(L);
  decode_outcome outcome = parse_value(L, vm_lease, json_str, json_str_len,
                                       max_depth, desired_buffer_size);
  if (outcome.status != decode_status::ok) {
    lua_settop(L, initial_top);
    return raise_decode_error(L, outcome);
  }

  return 1;
}

static int parse_file(lua_State *L) {
  int argument_count = lua_gettop(L);
  luaL_argcheck(L, argument_count >= 1 && argument_count <= 2, 1,
                "expected 1 or 2 arguments");
  size_t json_file_len = 0;
  const char *json_file = luaL_checklstring(L, 1, &json_file_len);

  int max_depth = read_max_decode_depth(L);
  size_t desired_buffer_size = read_decode_buffer_size(L);
  if (argument_count == 2) {
    luaL_checktype(L, 2, LUA_TTABLE);
    parse_decode_options(L, 2, max_depth, desired_buffer_size);
  }

  decode_vm_lease *vm_lease = ensure_decode_vm_lease(L);
  const int initial_top = lua_gettop(L);
  decode_outcome outcome = parse_file_value(
      L, vm_lease, json_file, json_file_len, max_depth, desired_buffer_size);
  if (outcome.status != decode_status::ok) {
    lua_settop(L, initial_top);
    return raise_decode_error(L, outcome);
  }

  return 1;
}

static int set_max_decode_depth(lua_State *L) {
  int max_depth = check_decode_depth(L, 1, "maximum decode depth");
  write_max_decode_depth(L, max_depth);
  return 0;
}

static int get_max_decode_depth(lua_State *L) {
  lua_pushinteger(L, read_max_decode_depth(L));
  return 1;
}

static int set_decode_buffer_size(lua_State *L) {
  size_t buffer_size = check_decode_buffer_size(L, 1, "decode buffer size");
  write_decode_buffer_size(L, buffer_size);
  return 0;
}

static int get_decode_buffer_size(lua_State *L) {
  lua_pushinteger(L, static_cast<lua_Integer>(read_decode_buffer_size(L)));
  return 1;
}

static int debug_decode_capacities(lua_State *L) {
  decode_vm_lease *caller_vm = ensure_decode_vm_lease(L);
  lua_State *active_thread =
      (tls_decode_state.in_use && tls_decode_state.owner_vm != nullptr)
          ? tls_decode_state.owner_vm->active_thread
          : nullptr;
  int start_level = (active_thread == L) ? 1 : 0;
  bool in_use = tls_decode_state.in_use &&
                is_decode_active_on_call_stack(active_thread, start_level);
  if (tls_decode_state.in_use && !in_use) {
    if (tls_decode_state.owner_vm != nullptr) {
      lua_State *cleanup_thread =
          (tls_decode_state.owner_vm == caller_vm) ? L : active_thread;
      write_active_decode_thread(tls_decode_state.owner_vm, cleanup_thread,
                                 false);
    }
    tls_decode_state.in_use = false;
    tls_decode_state.owner_vm = nullptr;
  }
  lua_newtable(L);
  lua_pushinteger(
      L, static_cast<lua_Integer>(tls_decode_state.parse_buffer_capacity));
  lua_setfield(L, -2, "parseBuffer");
  lua_pushinteger(
      L, static_cast<lua_Integer>(tls_decode_state.file_parse_buffer.size()));
  lua_setfield(L, -2, "fileBuffer");
  lua_pushinteger(L,
                  static_cast<lua_Integer>(tls_decode_state.parser.capacity()));
  lua_setfield(L, -2, "parserCapacity");
  lua_pushboolean(L, in_use ? 1 : 0);
  lua_setfield(L, -2, "inUse");
  return 1;
}

static LUA_SIMDJSON_NOINLINE bool
format_active_implementation(char *buffer, size_t buffer_size,
                             size_t &out_length) noexcept {
  out_length = 0;
  if (buffer == nullptr || buffer_size == 0) {
    return false;
  }
  try {
    const auto &implementation = simdjson::get_active_implementation();
    std::string name = implementation->name();
    std::string description = implementation->description();
    if (name.size() + description.size() + 3 >= buffer_size) {
      return false;
    }
    size_t pos = 0;
    std::memcpy(buffer + pos, name.data(), name.size());
    pos += name.size();
    buffer[pos++] = ' ';
    buffer[pos++] = '(';
    std::memcpy(buffer + pos, description.data(), description.size());
    pos += description.size();
    buffer[pos++] = ')';
    buffer[pos] = '\0';
    out_length = pos;
    return true;
  } catch (...) {
    buffer[0] = '\0';
    return false;
  }
}

static int active_implementation(lua_State *L) {
  char buffer[256];
  size_t length = 0;
  if (!format_active_implementation(buffer, sizeof(buffer), length)) {
    return luaL_error(L, "failed to retrieve active implementation");
  }
  lua_pushlstring(L, buffer, length);
  return 1;
}

// ParsedObject as C++ class
#define LUA_MYOBJECT "ParsedObject"
static int ParsedObject_atPointer(lua_State *L);

static int count_cfunction_frames_on_call_stack(lua_State *L, int start_level,
                                                lua_CFunction target) {
  if (L == nullptr || lua_status(L) != 0) {
    return 0;
  }
  int count = 0;
  lua_Debug ar;
  for (int level = start_level; lua_getstack(L, level, &ar) != 0; ++level) {
    if (!lua_checkstack(L, 1)) {
      return count + 1;
    }
    if (lua_getinfo(L, "f", &ar) != 0) {
      lua_CFunction fn = lua_tocfunction(L, -1);
      lua_pop(L, 1);
      if (fn == target) {
        ++count;
      }
    }
  }
  return count;
}

class ParsedObject {
private:
  simdjson::padded_string json_string;
  ondemand::document doc;
  std::unique_ptr<ondemand::parser> parser;

  ParsedObject() = default;

public:
  bool in_use = false;
  int active_depth = 0;
  int active_thread_ref = LUA_NOREF;
  lua_State *active_thread = nullptr;

  ~ParsedObject() = default;
  ondemand::document *get_doc() { return &(this->doc); }

  void set_active_thread(lua_State *L) {
    lua_pushthread(L);
    active_thread_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    active_thread = L;
  }

  void clear_active_thread(lua_State *L) {
    if (active_thread_ref != LUA_NOREF && L != nullptr) {
      luaL_unref(L, LUA_REGISTRYINDEX, active_thread_ref);
      active_thread_ref = LUA_NOREF;
    }
    active_thread = nullptr;
  }

  static LUA_SIMDJSON_NOINLINE decode_outcome create_from_string(
      const char *json_str, size_t json_str_len, ParsedObject **out) noexcept {
    *out = nullptr;
    if (json_str_len > std::numeric_limits<size_t>::max() - SIMDJSON_PADDING) {
      return {decode_status::input_too_large, simdjson::SUCCESS, 0};
    }

    std::unique_ptr<ParsedObject> obj(new (std::nothrow) ParsedObject());
    if (!obj) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }

    obj->parser.reset(new (std::nothrow) ondemand::parser{});
    if (!obj->parser) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }

    obj->json_string = simdjson::padded_string(json_str, json_str_len);
    if (obj->json_string.data() == nullptr) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }

    if (auto error = obj->parser->iterate(obj->json_string).get(obj->doc);
        error) {
      return {decode_status::simdjson_error, error, 0};
    }

    *out = obj.release();
    return {decode_status::ok, simdjson::SUCCESS, 0};
  }

  static LUA_SIMDJSON_NOINLINE decode_outcome
  create_from_file(const char *json_file, size_t json_file_len,
                   ParsedObject **out) noexcept {
    *out = nullptr;
    if (std::memchr(json_file, '\0', json_file_len) != nullptr) {
      return {decode_status::simdjson_error, simdjson::IO_ERROR, 0};
    }

    std::unique_ptr<ParsedObject> obj(new (std::nothrow) ParsedObject());
    if (!obj) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }

    obj->parser.reset(new (std::nothrow) ondemand::parser{});
    if (!obj->parser) {
      return {decode_status::allocation_failed, simdjson::SUCCESS, 0};
    }

    if (auto error =
            simdjson::padded_string::load(json_file).get(obj->json_string);
        error) {
      return {decode_status::simdjson_error, error, 0};
    }

    if (auto error = obj->parser->iterate(obj->json_string).get(obj->doc);
        error) {
      return {decode_status::simdjson_error, error, 0};
    }

    *out = obj.release();
    return {decode_status::ok, simdjson::SUCCESS, 0};
  }
};

static int ParsedObject_delete(lua_State *L) {
  ParsedObject **slot = reinterpret_cast<ParsedObject **>(lua_touserdata(L, 1));
  if (slot != nullptr && *slot != nullptr) {
    (*slot)->clear_active_thread(L);
    delete *slot;
    *slot = nullptr;
  }
  return 0;
}

static int ParsedObject_open(lua_State *L) {
  size_t json_str_len = 0;
  const char *json_str = luaL_checklstring(L, 1, &json_str_len);

  ParsedObject **slot = reinterpret_cast<ParsedObject **>(
      lua_newuserdata(L, sizeof(ParsedObject *)));
  *slot = nullptr;
  luaL_getmetatable(L, LUA_MYOBJECT);
  lua_setmetatable(L, -2);

  decode_outcome outcome =
      ParsedObject::create_from_string(json_str, json_str_len, slot);
  if (outcome.status != decode_status::ok) {
    return raise_decode_error(L, outcome);
  }
  return 1;
}

static int ParsedObject_open_file(lua_State *L) {
  size_t json_file_len = 0;
  const char *json_file = luaL_checklstring(L, 1, &json_file_len);

  ParsedObject **slot = reinterpret_cast<ParsedObject **>(
      lua_newuserdata(L, sizeof(ParsedObject *)));
  *slot = nullptr;
  luaL_getmetatable(L, LUA_MYOBJECT);
  lua_setmetatable(L, -2);

  decode_outcome outcome =
      ParsedObject::create_from_file(json_file, json_file_len, slot);
  if (outcome.status != decode_status::ok) {
    return raise_decode_error(L, outcome);
  }
  return 1;
}

struct parsed_object_lease {
  ParsedObject *obj;
  lua_State *lease_thread;
  bool acquired;

  parsed_object_lease(lua_State *L, ParsedObject *target)
      : obj(target), lease_thread(L), acquired(false) {
    lua_State *prev_thread = target->active_thread;
    int start_level = (prev_thread == L) ? 1 : 0;
    int active_frames = count_cfunction_frames_on_call_stack(
        prev_thread, start_level, ParsedObject_atPointer);
    if (!target->in_use || active_frames < target->active_depth) {
      target->clear_active_thread(L);
      target->set_active_thread(L);
      target->active_depth =
          count_cfunction_frames_on_call_stack(L, 0, ParsedObject_atPointer);
      target->in_use = true;
      acquired = true;
    }
  }

  ~parsed_object_lease() {
    if (acquired && obj != nullptr) {
      obj->clear_active_thread(lease_thread);
      obj->in_use = false;
      obj->active_depth = 0;
    }
  }
};

static LUA_SIMDJSON_NOINLINE decode_outcome
at_pointer_value(lua_State *L, ParsedObject *object_holder, const char *pointer,
                 size_t pointer_len, int max_depth) {
  parsed_object_lease lease(L, object_holder);
  if (!lease.acquired) {
    return {decode_status::object_in_use, simdjson::SUCCESS, 0};
  }
  ondemand::document *document = object_holder->get_doc();
  decode_context context{max_depth};
  if (pointer_len == 0) {
    if (!document->is_alive()) {
      return {decode_status::simdjson_error, simdjson::UNINITIALIZED, 0};
    }
    document->rewind();
    if (!convert_ondemand_element_to_table(L, *document, context)) {
      return {context.status, context.error, context.detail};
    }
    if (!document->at_end()) {
      return {decode_status::simdjson_error, simdjson::TRAILING_CONTENT, 0};
    }
    return {decode_status::ok, simdjson::SUCCESS, 0};
  }

  ondemand::value returned_element;
  if (auto error = document->at_pointer(std::string_view(pointer, pointer_len))
                       .get(returned_element);
      error) {
    return {decode_status::simdjson_error, error, 0};
  }
  if (!convert_ondemand_element_to_table(L, returned_element, context)) {
    return {context.status, context.error, context.detail};
  }
  return {decode_status::ok, simdjson::SUCCESS, 0};
}

static int ParsedObject_atPointer(lua_State *L) {
  int argument_count = lua_gettop(L);
  luaL_argcheck(L, argument_count >= 2 && argument_count <= 3, 2,
                "expected 2 or 3 arguments");
  ParsedObject **slot =
      reinterpret_cast<ParsedObject **>(luaL_checkudata(L, 1, LUA_MYOBJECT));
  if (slot == nullptr || *slot == nullptr) {
    return luaL_error(L, "invalid ParsedObject");
  }
  ParsedObject *object_holder = *slot;
  size_t pointer_len = 0;
  const char *pointer = luaL_checklstring(L, 2, &pointer_len);

  int max_depth = read_max_decode_depth(L);
  size_t desired_buffer_size = read_decode_buffer_size(L);
  if (argument_count == 3) {
    luaL_checktype(L, 3, LUA_TTABLE);
    parse_decode_options(L, 3, max_depth, desired_buffer_size);
  }
  (void)desired_buffer_size;

  const int initial_top = lua_gettop(L);
  decode_outcome outcome =
      at_pointer_value(L, object_holder, pointer, pointer_len, max_depth);
  if (outcome.status != decode_status::ok) {
    lua_settop(L, initial_top);
    return raise_decode_error(L, outcome);
  }

  return 1;
}

static int ParsedObject_newindex(lua_State *L) {
  luaL_error(
      L,
      "This should be treated as a read-only table. We may one day add array "
      "access for the elements, and it'll likely not be modifiable.");
  return 1;
}

static const struct luaL_Reg arraylib_m[] = {
    {"atPointer", ParsedObject_atPointer},
    {"__newindex", ParsedObject_newindex},
    {"__gc", ParsedObject_delete},
    {NULL, NULL}};

int luaopen_simdjson(lua_State *L) {
  ensure_decode_vm_lease(L);

  luaL_newmetatable(L, LUA_MYOBJECT);
  lua_pushvalue(L, -1); /* duplicates the metatable */
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, arraylib_m, 0);
  lua_pop(L, 1);

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
