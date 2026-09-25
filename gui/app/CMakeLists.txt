cmake_minimum_required(VERSION 3.21)
project(flux-gui VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick Network)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(flux-gui
    src/main.cpp
    src/fluxbackend.cpp
    src/themewatcher.cpp
    src/singleinstance.cpp
)

target_compile_definitions(flux-gui PRIVATE FLUX_VERSION="${PROJECT_VERSION}")
target_link_libraries(flux-gui PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network)

# The shared views use plain directory imports with qmldir files, so they
# go into the resources with the same layout, and not into a QML module.
set(FLUX_SHARED_QML "${CMAKE_CURRENT_SOURCE_DIR}/../qml" CACHE PATH "Folder of the shared Flux QML")
file(GLOB_RECURSE flux_shared_files CONFIGURE_DEPENDS
    "${FLUX_SHARED_QML}/*.qml"
    "${FLUX_SHARED_QML}/*.js"
    "${FLUX_SHARED_QML}/*.json"
    "${FLUX_SHARED_QML}/*qmldir"
)
if(flux_shared_files)
    qt_add_resources(flux-gui "flux_shared"
        PREFIX "/flux/qml"
        BASE "${FLUX_SHARED_QML}"
        FILES ${flux_shared_files}
    )
else()
    message(WARNING "No shared QML in ${FLUX_SHARED_QML}. Run flux-gui with FLUX_QML_DIR.")
endif()

qt_add_resources(flux-gui "flux_app"
    PREFIX "/flux/app"
    BASE "qml"
    FILES qml/Main.qml
)

# The app icon, so that the window has the Flux mark also when the icon
# theme has no flux icon. It needs the Qt SVG plugin at run time.
set(FLUX_DIST "${CMAKE_CURRENT_SOURCE_DIR}/../../dist" CACHE PATH "Folder of the Flux desktop files")
qt_add_resources(flux-gui "flux_icon"
    PREFIX "/flux/icons"
    BASE "${FLUX_DIST}"
    FILES "${FLUX_DIST}/flux.svg"
)

install(TARGETS flux-gui RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
