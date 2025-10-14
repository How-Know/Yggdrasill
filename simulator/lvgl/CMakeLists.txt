cmake_minimum_required(VERSION 3.20)
project(m5_lvgl_sdl_sim C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Option: allow vcpkg toolchain on Windows
# cmake -B build -S . -G "Ninja" -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake

include(FetchContent)

FetchContent_Declare(lvgl
  GIT_REPOSITORY https://github.com/lvgl/lvgl.git
  GIT_TAG v9.1.0
)
FetchContent_MakeAvailable(lvgl)

# Disable building LVGL demos/examples to avoid extra dependency on lv_conf.h include resolution
set(LV_CONF_BUILD_DISABLE_DEMOS ON CACHE BOOL "" FORCE)
set(LV_CONF_BUILD_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)

find_package(SDL2 CONFIG REQUIRED)

add_executable(m5_lvgl_sim
  main.c
  lv_conf.h
)

target_include_directories(m5_lvgl_sim PRIVATE ${lvgl_SOURCE_DIR} ${lvgl_SOURCE_DIR}/src ${CMAKE_CURRENT_SOURCE_DIR} ${lvgl_SOURCE_DIR}/src/drivers)
target_link_libraries(m5_lvgl_sim PRIVATE lvgl::lvgl SDL2::SDL2 $<TARGET_NAME_IF_EXISTS:SDL2::SDL2main>)

# Use simple include for lv_conf.h and expose our folder to both targets
target_compile_definitions(m5_lvgl_sim PRIVATE LV_CONF_INCLUDE_SIMPLE)

# Ensure LVGL also sees SDL2 when LV_USE_SDL=1
if (TARGET lvgl)
  target_link_libraries(lvgl PRIVATE SDL2::SDL2 $<TARGET_NAME_IF_EXISTS:SDL2::SDL2main>)
  get_target_property(_sdl_inc SDL2::SDL2 INTERFACE_INCLUDE_DIRECTORIES)
  if (_sdl_inc)
    target_include_directories(lvgl PRIVATE ${_sdl_inc})
  endif()
  target_include_directories(lvgl PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(lvgl PRIVATE LV_CONF_INCLUDE_SIMPLE)
endif()

# On Windows console, ensure UTF-8
if (WIN32)
  add_compile_definitions(UNICODE _UNICODE)
endif()


