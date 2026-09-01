# livi-statusui — LVGL idle screen, drawn straight on KMS/DRM.
#
# Build on Linux arm64 (the same container that builds the headless bundle):
#     apt-get install -y cmake build-essential libdrm-dev pkg-config
#     cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
# The binary lands at build/livi-statusui; ship it as statusui/livi-statusui
# inside dist-headless/.
cmake_minimum_required(VERSION 3.16)
project(livi-statusui C)

set(CMAKE_C_STANDARD 11)

# LVGL reads this cache var and force-includes our lv_conf.h.
set(LV_CONF_PATH ${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h CACHE STRING "" FORCE)

include(FetchContent)
FetchContent_Declare(
  lvgl
  GIT_REPOSITORY https://github.com/lvgl/lvgl.git
  GIT_TAG v9.2.2
  GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(lvgl)

find_package(PkgConfig REQUIRED)
pkg_check_modules(DRM REQUIRED libdrm)

# lvgl's own DRM driver (lv_linux_drm.c) includes libdrm headers too.
target_include_directories(lvgl PUBLIC ${DRM_INCLUDE_DIRS})
target_link_libraries(lvgl PUBLIC ${DRM_LIBRARIES})

add_executable(livi-statusui main.c)
target_link_libraries(livi-statusui PRIVATE lvgl m)
