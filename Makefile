OBJ = src/luasimdjson.o src/simdjson.o
CPPFLAGS = -I$(LUA_INCDIR)
CXXFLAGS = -std=c++11 -Wall $(CFLAGS)
LDFLAGS = $(LIBFLAG)
LDLIBS = -lpthread

ifdef LUA_LIBDIR
LDFLAGS += -L$(LUA_LIBDIR)
endif

ifeq ($(OS),Windows_NT)
	LIBEXT = dll
else
	UNAME_S := $(shell uname -s)
	ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
		LIBEXT = dll
	else ifeq ($(findstring CYGWIN,$(UNAME_S)),CYGWIN)
		LIBEXT = dll
	else
		LIBEXT = so
	endif
endif

TARGET = simdjson.$(LIBEXT)

all: $(TARGET)

DEP_FILES = $(OBJ:.o=.d)
-include $(DEP_FILES)

%.o: %.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(TARGET): $(OBJ)
ifeq ($(UNAME_S),Darwin)
	$(CXX) -bundle -undefined dynamic_lookup $(LDFLAGS) $^ -o $@ $(LDLIBS)
else
	$(CXX) -shared $(LDFLAGS) $^ -o $@ $(LDLIBS)
endif

clean:
	rm -f *.$(LIBEXT) src/*.{o,d}

install: $(TARGET)
	cp $(TARGET) $(INST_LIBDIR)
