cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "helper_pipe.cpp"
  "helper_pipe.h"
  "helper_pipe_io.cpp"
  "helper_pipe_io.h"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# OpenSCManagerW/QueryServiceStatusEx (peer authentication in helper_pipe_io.cpp).
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Standalone test for the boltmeshd named-pipe transport. It links no Flutter
# libraries, so it can be built and run on the Windows CI runner (see the
# validate-windows job) even though the app itself needs a GUI toolchain.
#
# EXCLUDE_FROM_ALL is load-bearing: Flutter builds the INSTALL target, and the
# fastforge exe packager copies the entire runner output directory into the
# installer's [Files] wildcard. As an ALL target this test exe would be built
# next to boltmesh.exe and shipped. The validate-windows job builds it by name.
add_executable(helper_pipe_io_tests EXCLUDE_FROM_ALL
  "tests/helper_pipe_io_test.cpp"
  "helper_pipe_io.cpp"
  "helper_pipe_io.h"
)
apply_standard_settings(helper_pipe_io_tests)
# Defines the test-only unauthenticated entry point in helper_pipe_io.cpp. The
# app target deliberately does not get it, so the shipped binary exposes only
# the authenticating ExchangePipe.
target_compile_definitions(helper_pipe_io_tests PRIVATE "NOMINMAX" "BOLTMESH_HELPER_PIPE_TEST")
target_link_libraries(helper_pipe_io_tests PRIVATE "kernel32.lib" "advapi32.lib")
