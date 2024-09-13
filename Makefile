OBJ = src/luasimdjson.o src/simdjson.o
INCLUDE = -I$(LUA_INCDIR)
FLAGS = -std=c++11 -Wall $(CFLAGS)
LDFLAGS = $(LIBFLAG)
LIBS = -lpthread

ifdef LUA_LIBDIR
LIBS += $(LUA_LIBDIR)/$(LUALIB)
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
	$(CXX) $(INCLUDE) $(FLAGS) -c $< -o $@

$(TARGET): $(OBJ)
	$(CC) $(LDFLAGS) $^ -o $@ $(LIBS)

clean:
	rm -f *.$(LIBEXT) src/*.o

install: $(TARGET)
	cp $(TARGET) $(INST_LIBDIR)
