SRC = src/luasimdjson.cpp src/simdjson.cpp
INCLUDE = -I$(LUA_INCDIR)
LIBS_PATH = -L$(LUA_LIBDIR)
LIBS = -lpthread
FLAGS = -std=c++11 -Wall $(LIBFLAG) $(CFLAGS)

all: simdjson.so

simdjson.so:
	$(CXX) $(SRC) $(FLAGS) $(INCLUDE) $(LIBS_PATH) $(LIBS) -o $@

clean:
	rm *.so

install: simdjson.so
	cp simdjson.so $(INST_LIBDIR)
