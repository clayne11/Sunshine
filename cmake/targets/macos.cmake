# macos specific target definitions

if (SUNSHINE_BUILD_HOMEBREW)
    target_link_options(sunshine PRIVATE LINKER:-sectcreate,__TEXT,__info_plist,${APPLE_PLIST_FILE})
else()
    # .app build
    set_target_properties(sunshine PROPERTIES
            OUTPUT_NAME "${CMAKE_PROJECT_NAME}"
            MACOSX_BUNDLE_BUNDLE_NAME "${CMAKE_PROJECT_NAME}"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${PROJECT_FQDN}"
            MACOSX_BUNDLE_INFO_PLIST "${APPLE_PLIST_FILE}"
            MACOSX_BUNDLE_ICON_FILE "sunshine.icns"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}")

    # Populate bundle resources in the build tree for local runs.
    set(_bundle_resources_dir "$<TARGET_FILE_DIR:sunshine>/../Resources")
    add_custom_command(TARGET sunshine POST_BUILD
            COMMENT "Copying bundle resources to build tree"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${_bundle_resources_dir}"
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/assets" "${_bundle_resources_dir}/assets"
            VERBATIM)
endif()

# Tell linker to dynamically load these symbols at runtime, in case they're unavailable:
target_link_options(sunshine PRIVATE -Wl,-U,_CGPreflightScreenCaptureAccess -Wl,-U,_CGRequestScreenCaptureAccess)

# Keep private virtual-display APIs in a small helper process. Its lifetime
# follows Sunshine, and the controller expects it beside the server executable.
add_executable(vd_helper
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/display_preferences.cpp")
set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/src/platform/macos/vd_helper.m"
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_link_libraries(vd_helper PRIVATE
        nlohmann_json::nlohmann_json
        "-framework Foundation"
        "-framework AppKit"
        "-framework CoreGraphics"
        "-F/System/Library/PrivateFrameworks"
        "-framework SkyLight")
add_dependencies(sunshine vd_helper)

if(SUNSHINE_BUILD_HOMEBREW)
    install(TARGETS vd_helper RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    add_custom_command(TARGET sunshine POST_BUILD
            COMMENT "Copying virtual-display helper into the app bundle"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "$<TARGET_FILE:vd_helper>" "$<TARGET_FILE_DIR:sunshine>/vd_helper"
            VERBATIM)
    install(TARGETS vd_helper
            RUNTIME DESTINATION "${CMAKE_PROJECT_NAME}.app/Contents/MacOS"
            COMPONENT Runtime)
endif()
