SRC = src/luasimdjson.cpp src/simdjson.cpp
INCLUDE = -I$(LUA_INCDIR)
LIBS = -lpthread
FLAGS = -std=c++11 -Wall -g $(LIBFLAG) $(CFLAGS)

ifdef LUA_LIBDIR
FLAGS += $(LUA_LIBDIR)/$(LUALIB)
endif

ifeq ($(OS),Windows_NT)
	LIBEXT = dll
else
	UNAME := $(shell uname -s)
	ifeq ($(findstring MINGW,$(UNAME)),MINGW)
		LIBEXT = dll
	else ifeq ($(findstring CYGWIN,$(UNAME)),CYGWIN)
		LIBEXT = dll
	else
		LIBEXT = so
	endif
endif

TARGET = simdjson.$(LIBEXT)

all: $(TARGET)

$(TARGET):
	$(CXX) $(SRC) $(FLAGS) $(INCLUDE) $(LIBS_PATH) $(LIBS) -o $@

clean:
	rm *.$(LIBEXT)

install: $(TARGET)
	cp $(TARGET) $(INST_LIBDIR)
