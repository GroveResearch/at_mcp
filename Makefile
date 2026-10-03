# Build the application-owned advisory lock NIF (derived from flock_ex 0.1.0;
# Apache-2.0, see licenses/flock_ex).
#
# Makefile targets:
#
# all    build and install the NIF
# clean  clean build products and intermediates
#
# Variables to override:
#
# MIX_APP_PATH  path to the build directory
#
# CC            The C compiler
# CROSSCOMPILE  crosscompiler prefix, if any
# CFLAGS        compiler flags for compiling all C files
# LDFLAGS       linker flags for linking all binaries
# ERL_CFLAGS	additional compiler flags for files using Erlang header files
# ERL_EI_INCLUDE_DIR include path to header files (Possibly required for crosscompile)

NIF_NAME = native_lock
PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj
SRC = c_src/$(NIF_NAME).c
OBJ = $(SRC:c_src/%.c=$(BUILD)/%.o)
LIB_NAME = $(PREFIX)/$(NIF_NAME).so

KERNEL_NAME := $(shell uname -s)

CFLAGS += -I"$(ERTS_INCLUDE_DIR)"

ifneq ($(DEBUG),)
	CFLAGS += -g
else
	CFLAGS += -DNDEBUG=1 -O2
endif


ifneq ($(CROSSCOMPILE),)
	ifeq ($(CROSSCOMPILE), Android)
		CFLAGS += -fPIC -Os -z global
		LDFLAGS += -fPIC -shared -lm
	else
		CFLAGS += -fPIC -fvisibility=hidden
		LDFLAGS += -fPIC -shared
	endif
else
	ifeq ($(KERNEL_NAME), Linux)
		CFLAGS += -fPIC -fvisibility=hidden
		LDFLAGS += -fPIC -shared
	endif
	ifeq ($(KERNEL_NAME), Darwin)
		CFLAGS += -fPIC
		LDFLAGS += -dynamiclib -undefined dynamic_lookup
	endif
	ifeq (MINGW, $(findstring MINGW,$(KERNEL_NAME)))
		CFLAGS += -fPIC
		LDFLAGS += -fPIC -shared
		LIB_NAME = $(PREFIX)/sqlite3_nif.dll
	endif
	ifeq ($(KERNEL_NAME), $(filter $(KERNEL_NAME),OpenBSD FreeBSD NetBSD))
		CFLAGS += -fPIC
		LDFLAGS += -fPIC -shared
	endif
endif

# Set Erlang-specific compile flags
ifeq ($(CC_PRECOMPILER_CURRENT_TARGET),armv7l-linux-gnueabihf)
	ERL_CFLAGS ?= -I"$(PRECOMPILE_ERL_EI_INCLUDE_DIR)"
else
	ERL_CFLAGS ?= -I"$(ERL_EI_INCLUDE_DIR)"
endif
ERL_LDFLAGS ?= -L$(ERL_EI_LIBDIR) -lei


all: $(PREFIX) $(BUILD) $(LIB_NAME)

$(BUILD)/%.o: c_src/%.c
	@echo " CC $(notdir $@)"
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(LIB_NAME): $(OBJ)
	@echo " LD $(notdir $@)"
	$(CC) -o $@ $(ERL_LDFLAGS) $(LDFLAGS) $^

$(PREFIX) $(BUILD):
	mkdir -p $@

clean:
	$(RM) $(LIB_NAME) $(OBJ)

.PHONY: all clean
