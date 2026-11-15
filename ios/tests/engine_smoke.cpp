// Exercise import -> slice -> processed preview -> export through the mobile ABI.
#include "orca_slice_c_api.h"

#include <cmath>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>

int main(int argc, char **argv)
{
    if (argc != 2)
        return 2;
    const std::string directory = argv[1];
    const std::string project = directory + "/cube.3mf";
    const std::string output = directory + "/cube.gcode";
    std::unique_ptr<orca_session_t, decltype(&orca_session_destroy)>
        session(orca_session_create(nullptr), orca_session_destroy);
    if (!session)
        return 3;
    auto require = [&](bool condition, const char *message) {
        if (!condition)
            std::fprintf(stderr, "%s: %s\n", message, orca_session_last_error(session.get()));
        return condition;
    };
    if (!require(orca_session_add_box(session.get(), "Smoke cube", 20, 20, 20) >= 0, "create cube") ||
        !require(orca_session_repair_mesh(session.get(), 0) == 0, "repair cube through current engine API") ||
        !require(orca_session_save_3mf(session.get(), project.c_str()) == 0, "save project") ||
        !require(orca_session_load_model(session.get(), project.c_str()) == 0, "import project"))
        return 4;
    const char *options[][2] = {
        {"layer_height", "0.2"}, {"wall_loops", "2"},
        {"sparse_infill_density", "15%"}, {"filament_diameter", "1.75"},
        {"nozzle_diameter", "0.4"}, {"printable_area", "0x0,220x0,220x220,0x220"},
        {"printable_height", "250"}
    };
    for (const auto &option : options)
        if (!require(orca_session_set_option(session.get(), option[0], option[1]) == 0, option[0]))
            return 5;
    if (!require(orca_session_slice_to_gcode(session.get(), output.c_str()) == 0, "slice"))
        return 6;
    std::ifstream stream(output);
    const std::string gcode((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    if (!require(gcode.find(";TYPE:") != std::string::npos, "export contains toolpaths"))
        return 7;
    orca_preview_segment_t *segments = nullptr;
    size_t count = 0, total = 0;
    if (!require(orca_session_export_preview(session.get(), &segments, &count, &total) == 0,
                 "export processed preview"))
        return 8;
    std::unique_ptr<orca_preview_segment_t, decltype(&orca_free)> preview(segments, orca_free);
    if (!require(count > 0 && count <= 60000 && total >= count, "preview is populated and bounded"))
        return 9;
    float max_z = 0.f;
    for (size_t i = 0; i < count; ++i) {
        if (!require(std::isfinite(segments[i].end_z), "finite preview coordinates"))
            return 10;
        if (!segments[i].travel && segments[i].end_z > max_z)
            max_z = segments[i].end_z;
    }
    if (!require(max_z > 19.f, "preview reaches the top of the cube"))
        return 11;
    // A failed next slice must invalidate the prior successful statistics/preview.
    if (!require(orca_session_set_option(session.get(), "layer_height", "5") == 0, "set invalid layer height") ||
        !require(orca_session_slice_to_gcode(session.get(), (directory + "/invalid.gcode").c_str()) != 0,
                 "reject layer height above nozzle diameter"))
        return 12;
    orca_preview_segment_t *stale = nullptr;
    size_t stale_count = 0, stale_total = 0;
    if (!require(orca_session_export_preview(session.get(), &stale, &stale_count, &stale_total) != 0,
                 "failed slice cannot export stale preview")) {
        orca_free(stale);
        return 13;
    }
    if (!require(orca_session_set_option(session.get(), "layer_height", "0.2") == 0, "restore valid layer height"))
        return 14;
    orca_session_set_progress_callback(session.get(), [](int percent, const char *, void *user) {
        if (percent >= 15)
            orca_session_cancel_slice(static_cast<orca_session_t *>(user));
    }, session.get());
    const int cancelled = orca_session_slice_to_gcode(session.get(), (directory + "/cancelled.gcode").c_str());
    orca_session_set_progress_callback(session.get(), nullptr, nullptr);
    if (!require(cancelled == -7, "cancel active slice"))
        return 15;
    if (!require(orca_session_slice_to_gcode(session.get(), (directory + "/recovered.gcode").c_str()) == 0,
                 "slice again after cancellation"))
        return 16;
    std::printf("PASS: 3MF import, slicing, G-code export, processed preview, validation, cancellation and recovery\n");
    return 0;
}
