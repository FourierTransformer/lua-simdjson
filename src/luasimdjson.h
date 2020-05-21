#include <lua.hpp>
extern "C" {
	static int parse(lua_State*);
	static int parse_file(lua_State*);
	static int ParsedObject_open(lua_State*);
	static int ParsedObject_open_file(lua_State*);


	static const struct luaL_Reg luasimdjson[] = {
		{"parse", parse},
		{"parseFile", parse_file},
		{"open", ParsedObject_open},
		{"openFile", ParsedObject_open_file},
			
		{NULL, NULL},
	};
	int luaopen_simdjson (lua_State*);
}