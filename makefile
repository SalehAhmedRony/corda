MAKEFLAGS = -s

arch = $(shell uname -m)
ifeq ($(arch),i586)
	arch = i386
endif
ifeq ($(arch),i686)
	arch = i386
endif

platform = $(shell uname -s | tr [:upper:] [:lower:])

ifeq ($(platform),darwin)
	rdynamic =
	thread-cflags =
	shared = -dynamiclib
	so-extension = jnilib
	ld-library-path = DYLD_LIBRARY_PATH
else
	rdynamic = -rdynamic
	thread-cflags = -pthread
	shared = -shared
	so-extension = so
	ld-library-path = LD_LIBRARY_PATH
endif

process = interpret

mode = debug

bld = build/$(platform)/$(arch)/$(mode)
cls = build/classes
src = src
classpath = classpath
test = test

input = $(cls)/Exceptions.class

cxx = g++
cc = gcc
vg = nice valgrind --suppressions=valgrind.supp --undef-value-errors=no \
	--num-callers=32 --db-attach=yes --freelist-vol=100000000
db = gdb --args
javac = javac
strip = :
show-size = :

warnings = -Wall -Wextra -Werror -Wold-style-cast -Wunused-parameter \
	-Winit-self -Wconversion

thread-lflags = -lpthread

cflags = $(warnings) -fPIC -fno-rtti -fno-exceptions -fvisibility=hidden \
	-I$(src) -I$(bld) $(thread-cflags) -D__STDC_LIMIT_MACROS

lflags = $(thread-lflags) -ldl -lm -lz

ifeq ($(mode),debug)
cflags += -O0 -g3
endif
ifeq ($(mode),stress)
cflags += -O0 -g3 -DVM_STRESS
endif
ifeq ($(mode),stress-major)
cflags += -O0 -g3 -DVM_STRESS -DVM_STRESS_MAJOR
endif
ifeq ($(mode),fast)
cflags += -g3 -O3 -DNDEBUG
#strip = strip
#show-size = ls -l
endif

cpp-objects = $(foreach x,$(1),$(patsubst $(2)/%.cpp,$(bld)/%.o,$(x)))
asm-objects = $(foreach x,$(1),$(patsubst $(2)/%.S,$(bld)/%.o,$(x)))
java-classes = $(foreach x,$(1),$(patsubst $(2)/%.java,$(cls)/%.class,$(x)))

stdcpp-sources = $(src)/stdc++.cpp
stdcpp-objects = $(call cpp-objects,$(stdcpp-sources),$(src))

jni-sources = $(shell find $(classpath) -name '*.cpp')
jni-objects = $(call cpp-objects,$(jni-sources),$(classpath))
jni-cflags = -I$(JAVA_HOME)/include -I$(JAVA_HOME)/include/linux $(cflags)
jni-library = $(bld)/libnatives.$(so-extension)

generated-code = \
	$(bld)/type-enums.cpp \
	$(bld)/type-declarations.cpp \
	$(bld)/type-constructors.cpp \
	$(bld)/type-initializations.cpp \
	$(bld)/type-java-initializations.cpp

interpreter-depends = \
	$(generated-code) \
	$(src)/common.h \
	$(src)/system.h \
	$(src)/heap.h \
	$(src)/finder.h \
	$(src)/processor.h \
	$(src)/process.h \
	$(src)/stream.h \
	$(src)/constants.h \
	$(src)/jnienv.h \
	$(src)/machine.h

interpreter-sources = \
	$(src)/system.cpp \
	$(src)/finder.cpp \
	$(src)/machine.cpp \
	$(src)/heap.cpp \
	$(src)/$(process).cpp \
	$(src)/builtin.cpp \
	$(src)/jnienv.cpp \
	$(src)/main.cpp

interpreter-asm-sources = $(src)/vmInvoke.S

ifeq ($(arch),i386)
	interpreter-asm-sources += $(src)/cdecl.S
endif
ifeq ($(arch),x86_64)
	interpreter-asm-sources += $(src)/amd64.S
endif

interpreter-cpp-objects = \
	$(call cpp-objects,$(interpreter-sources),$(src))
interpreter-asm-objects = \
	$(call asm-objects,$(interpreter-asm-sources),$(src))
interpreter-objects = \
	$(interpreter-cpp-objects) \
	$(interpreter-asm-objects)

generator-headers = \
	$(src)/input.h \
	$(src)/output.h
generator-sources = \
	$(src)/type-generator.cpp
generator-objects = $(call cpp-objects,$(generator-sources),$(src))
generator-executable = $(bld)/generator

executable = $(bld)/vm

classpath-sources = $(shell find $(classpath) -name '*.java')
classpath-classes = $(call java-classes,$(classpath-sources),$(classpath))

classpath-objects = $(classpath-classes) $(jni-library)

test-sources = $(shell find $(test) -name '*.java')
test-classes = $(call java-classes,$(test-sources),$(test))

class-name = $(patsubst $(cls)/%.class,%,$(1))
class-names = $(foreach x,$(1),$(call class-name,$(x)))

flags = -cp $(cls)
args = $(flags) $(call class-name,$(input))

.PHONY: build
build: $(executable) $(classpath-objects) $(test-classes)

$(input): $(classpath-classes)

.PHONY: run
run: build
	$(ld-library-path)=$(bld) $(executable) $(args)

.PHONY: debug
debug: build
	LD_LIBRARY_PATH=$(bld) gdb --args $(executable) $(args)

.PHONY: vg
vg: build
	LD_LIBRARY_PATH=$(bld) $(vg) $(executable) $(args)

.PHONY: test
test: build
	LD_LIBRARY_PATH=$(bld) /bin/bash $(test)/test.sh 2>/dev/null \
		$(executable) $(mode) "$(flags)" $(call class-names,$(test-classes))

.PHONY: clean
clean:
	@echo "removing build"
	rm -rf build

.PHONY: clean-native
clean-native:
	@echo "removing $(bld)"
	rm -rf $(bld)

gen-arg = $(shell echo $(1) | sed -e 's:$(bld)/type-\(.*\)\.cpp:\1:')
$(generated-code): %.cpp: $(src)/types.def $(generator-executable)
	@echo "generating $(@)"
	$(generator-executable) $(call gen-arg,$(@)) < $(<) > $(@)

$(bld)/type-generator.o: \
	$(generator-headers)

define compile-class
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(javac) -bootclasspath $(classpath) -classpath $(classpath) \
		-d $(cls) $(<)
	@touch $(@)
endef

$(cls)/%.class: $(classpath)/%.java
	$(compile-class)

$(cls)/%.class: $(test)/%.java
	$(compile-class)

define compile-object
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(cflags) -c $(<) -o $(@)
endef

$(stdcpp-objects): $(bld)/%.o: $(src)/%.cpp
	$(compile-object)

$(interpreter-cpp-objects): $(bld)/%.o: $(src)/%.cpp $(interpreter-depends)
	$(compile-object)

$(interpreter-asm-objects): $(bld)/%.o: $(src)/%.S
	$(compile-object)

$(generator-objects): $(bld)/%.o: $(src)/%.cpp
	$(compile-object)

$(jni-objects): $(bld)/%.o: $(classpath)/%.cpp
	@echo "compiling $(@)"
	@mkdir -p $(dir $(@))
	$(cxx) $(jni-cflags) -c $(<) -o $(@)	

$(jni-library): $(jni-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(shared) $(^) -o $(@)

$(executable): $(interpreter-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(rdynamic) $(^) -o $(@)
	@$(strip) --strip-all $(@)
	@$(show-size) $(@)

.PHONY: generator
generator: $(generator-executable)

.PHONY: run-generator
run-generator: $(generator-executable)
	$(<) < $(src)/types.def

.PHONY: vg-generator
vg-generator: $(generator-executable)
	$(vg) $(<) < $(src)/types.def

$(generator-executable): $(generator-objects) $(stdcpp-objects)
	@echo "linking $(@)"
	$(cc) $(lflags) $(^) -o $(@)
