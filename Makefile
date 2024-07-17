SRC = src/luasimdjson.cpp src/simdjson.cpp
INCLUDE = -I$(LUA_INCDIR)
LIBS = -lpthread
FLAGS = -std=c++11 -Wall $(LIBFLAG) $(CFLAGS)

all: simdjson.so

simdjson.so:
	$(CXX) $(SRC) $(FLAGS) $(INCLUDE) $(LIBS) -o $@

clean:
	rm *.so

install: simdjson.so
	cp simdjson.so $(INST_LIBDIR)
