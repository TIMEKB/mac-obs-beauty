cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Plugin architecture")
set(CMAKE_OSX_DEPLOYMENT_TARGET 13.0 CACHE STRING "Minimum macOS version")
project(obs-live-beauty VERSION 0.7.0 LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(OBS_APP "/Applications/OBS.app" CACHE PATH "Installed arm64 OBS application")
set(OBS_SDK_ROOT "" CACHE PATH "OBS 32.2.1 headers: libobs, frontend/api and simde-0.8.2")
set(LB_QT_INCLUDE_ROOT "${OBS_SDK_ROOT}/qt6/include" CACHE PATH "Qt development headers matching OBS (6.11.1)")
option(LB_BUILD_STUB "Disabled pass-through engine for build checks only" OFF)
if(NOT APPLE)
  message(FATAL_ERROR "This plugin currently supports Apple Silicon macOS only")
endif()
if(NOT EXISTS "${OBS_SDK_ROOT}/libobs/obs-module.h")
  message(FATAL_ERROR "Set OBS_SDK_ROOT to OBS 32.2.1 headers (see README.md)")
endif()
if(NOT EXISTS "${LB_QT_INCLUDE_ROOT}/QtWidgets/QApplication")
  message(FATAL_ERROR "Set LB_QT_INCLUDE_ROOT to Qt development headers matching OBS")
endif()
add_library(obs-live-beauty MODULE src/obs-plugin.mm src/panel.mm src/obs-dock-host.mm src/beauty-shader.mm)
if(NOT LB_BUILD_STUB)
  target_sources(obs-live-beauty PRIVATE src/engine-driver.mm)
endif()
target_compile_definitions(obs-live-beauty PRIVATE LB_BUILD_STUB=$<BOOL:${LB_BUILD_STUB}>)
target_compile_options(obs-live-beauty PRIVATE -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter)
target_include_directories(obs-live-beauty PRIVATE
  "${OBS_SDK_ROOT}/libobs" "${OBS_SDK_ROOT}/frontend/api" "${OBS_SDK_ROOT}/simde-0.8.2"
  "${LB_QT_INCLUDE_ROOT}" "${LB_QT_INCLUDE_ROOT}/QtCore" "${LB_QT_INCLUDE_ROOT}/QtGui"
  "${LB_QT_INCLUDE_ROOT}/QtWidgets" "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(obs-live-beauty PRIVATE
  "${OBS_APP}/Contents/Frameworks/libobs.framework/Versions/A/libobs"
  "${OBS_APP}/Contents/Frameworks/obs-frontend-api.dylib"
  "${OBS_APP}/Contents/Frameworks/QtCore.framework/Versions/A/QtCore"
  "${OBS_APP}/Contents/Frameworks/QtGui.framework/Versions/A/QtGui"
  "${OBS_APP}/Contents/Frameworks/QtWidgets.framework/Versions/A/QtWidgets"
  "-framework AppKit" "-framework Foundation" "-framework OpenGL" "-framework WebKit")
set_target_properties(obs-live-beauty PROPERTIES
  BUNDLE TRUE BUNDLE_EXTENSION plugin PREFIX "" OUTPUT_NAME "obs-live-beauty"
  BUILD_RPATH "@executable_path/../Frameworks;${OBS_APP}/Contents/Frameworks"
  INSTALL_RPATH "@executable_path/../Frameworks")
set_property(TARGET obs-live-beauty APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/data/panel.html")
configure_file(Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
add_custom_command(TARGET obs-live-beauty POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" "$<TARGET_BUNDLE_DIR:obs-live-beauty>/Contents/Info.plist"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:obs-live-beauty>/Contents/Resources/locale"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/data/panel.html" "$<TARGET_BUNDLE_DIR:obs-live-beauty>/Contents/Resources/panel.html"
  COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/data/locale" "$<TARGET_BUNDLE_DIR:obs-live-beauty>/Contents/Resources/locale"
  COMMENT "Package original UI only; third-party runtime resources stay external")
