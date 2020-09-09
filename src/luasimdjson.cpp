#include <lua.hpp>
#include <lauxlib.h>

#include "simdjson.h"
#include "luasimdjson.h"

#define LUA_SIMDJSON_NAME       "simdjson"
#define LUA_SIMDJSON_VERSION    "0.0"

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

static simdjson::dom::parser parser;

void convert_element_to_table(lua_State *L, dom::element element) {
  switch (element.type()) {
    case dom::element_type::ARRAY:
      {
          int count = 0;
          lua_newtable(L);
          lua_getglobal(L, "_hx_array_mt");
          lua_setmetatable(L, 2);
          for (dom::element child : dom::array(element)) {
            lua_pushinteger(L, count);
            convert_element_to_table(L, child);

            lua_rawset(L, -3);
            count = count + 1;
          }
          lua_pushstring(L, "length");
          lua_pushnumber(L, count);
          lua_rawset(L, -3);
          break;
      }

    case dom::element_type::OBJECT:
      lua_newtable(L);
      for (dom::key_value_pair field : dom::object(element)) {

        std::string_view view(field.key);
        lua_pushlstring(L, view.data(), view.size());

        convert_element_to_table(L, field.value);
        lua_settable(L, -3);
      }
      break;

    case dom::element_type::INT64:
      lua_pushinteger(L, int64_t(element));
      break;

    case dom::element_type::UINT64:
      lua_pushinteger(L, int64_t(element));
      break;

    case dom::element_type::DOUBLE:
      lua_pushnumber(L, double(element));
      break;

    case dom::element_type::STRING:
      {
        std::string_view view(element);
        lua_pushlstring(L, view.data(), view.size());
        break;
      }

    case dom::element_type::BOOL:
      lua_pushboolean(L, bool(element));
      break;

    case dom::element_type::NULL_VALUE:
      lua_pushlightuserdata(L, NULL);
      break;
  }
}

static int parse(lua_State *L)
{
    size_t json_str_len;
    const char *json_str = luaL_checklstring(L, 1, &json_str_len);

    dom::element element;
    simdjson::error_code error;
    parser.parse(json_str, json_str_len).tie(element, error);

    if (error) {
        luaL_error(L, error_message(error));
        return 1;
    }

    convert_element_to_table(L, element);

    return 1;
}

static int parse_file(lua_State *L)
{
    const char *json_file = luaL_checkstring(L, 1);

    dom::element element;
    simdjson::error_code error;
    parser.load(json_file).tie(element, error);

    if (error) {
        luaL_error(L, error_message(error));
        return 1;
    }
    convert_element_to_table(L, element);

    return 1;
}

static int active_implementation(lua_State *L)
{
    std::string name = simdjson::active_implementation->name();
    std::string description = simdjson::active_implementation->description();
    std::string implementation_name = name + " (" + description + ")";

    lua_pushlstring(L, implementation_name.data(), implementation_name.size());

    return 1;
}

// ParsedObject as C++ class
#define LUA_MYOBJECT "ParsedObject"
class ParsedObject{
    private:
        dom::document* doc;
    public:
        ParsedObject(dom::document* doc) : doc(doc){}
        ~ParsedObject() { delete doc; }
        dom::document* get() const{return this->doc;}
};

static int ParsedObject_delete(lua_State* L){
    delete *reinterpret_cast<ParsedObject**>(lua_touserdata(L, 1));
    return 0;
}

static int ParsedObject_open(lua_State *L)
{
    size_t json_str_len;
    const char *json_str = luaL_checklstring(L, 1, &json_str_len);

    simdjson::error_code error = parser.parse(json_str, json_str_len).error();

    if (error) {
        luaL_error(L, error_message(error));
        return 1;
    }

    ParsedObject** parsedObject = (ParsedObject**)(lua_newuserdata(L, sizeof(ParsedObject*)));
    *parsedObject = new ParsedObject(new dom::document(std::move(parser.doc)));
    luaL_getmetatable(L, LUA_MYOBJECT);
    lua_setmetatable(L, -2);

    return 1;
}

static int ParsedObject_open_file(lua_State *L)
{
    const char *json_file = luaL_checkstring(L, 1);

    simdjson::error_code error = parser.load(json_file).error();

    if (error) {
        luaL_error(L, error_message(error));
        return 1;
    }

    ParsedObject** parsedObject = (ParsedObject**)(lua_newuserdata(L, sizeof(ParsedObject*)));
    *parsedObject = new ParsedObject(new dom::document(std::move(parser.doc)));
    luaL_getmetatable(L, LUA_MYOBJECT);
    lua_setmetatable(L, -2);

    return 1;
}

static int ParsedObject_at(lua_State *L) {
    dom::document* document = (*reinterpret_cast<ParsedObject**>(luaL_checkudata(L, 1, LUA_MYOBJECT)))->get();
    const char *pointer = luaL_checkstring(L, 2);

    dom::element returned_element;
    simdjson::error_code error;

    dom::element element = document->root();

    element.at(pointer).tie(returned_element, error);
    if (error) {
        luaL_error(L, error_message(error));
        return 1;
    }

    convert_element_to_table(L, returned_element);

    return 1;
}

static int ParsedObject_newindex(lua_State *L) {
    luaL_error(L, "This should be treated as a read-only table. We may one day add array access for the elements, and it'll likely not be modifiable.");
    return 1;
}

static const struct luaL_Reg arraylib_m [] = {
    {"at", ParsedObject_at},
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
