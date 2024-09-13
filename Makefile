OBJ = src/luasimdjson.o src/simdjson.o
CPPFLAGS = -I$(LUA_INCDIR)
CXXFLAGS = -std=c++11 -Wall $(CFLAGS)
LDFLAGS = $(LIBFLAG)
LDLIBS = -lpthread

ifdef LUA_LIBDIR
LDLIBS += $(LUA_LIBDIR)/$(LUALIB)
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

%.o: %.cpp %.h
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(TARGET): $(OBJ)
	$(CXX) $(LDFLAGS) $^ -o $@ $(LDLIBS)

clean:
	rm -f *.$(LIBEXT) src/*.o

install: $(TARGET)
	cp $(TARGET) $(INST_LIBDIR)
