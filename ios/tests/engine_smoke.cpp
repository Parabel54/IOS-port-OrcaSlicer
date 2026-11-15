// Exercise import -> slice -> processed preview -> export through the mobile ABI.
#include "orca_slice_c_api.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>

int main(int argc, char **argv)
{
    if (argc != 3)
        return 2;
    const std::string directory = argv[1];
    const std::string project = directory + "/cube.3mf";
    const std::string output = directory + "/cube.gcode";
    std::unique_ptr<orca_session_t, decltype(&orca_session_destroy)>
        session(orca_session_create(argv[2]), orca_session_destroy);
    if (!session)
        return 3;
    auto require = [&](bool condition, const char *message) {
        if (!condition)
            std::fprintf(stderr, "%s: %s\n", message, orca_session_last_error(session.get()));
        return condition;
    };
    // All desktop primitives must be real, bed-placed engine objects.
    for (int kind = 0; kind < 6; ++kind) {
        std::unique_ptr<orca_session_t, decltype(&orca_session_destroy)>
            shape(orca_session_create(argv[2]), orca_session_destroy);
        float b[6]{};
        if (!require(orca_session_add_primitive(shape.get(), kind, 20, 8, 12) == 0, "add primitive") ||
            !require(orca_session_model_bounds(shape.get(), b, b+1, b+2, b+3, b+4, b+5) == 0,
                     "primitive bounds") ||
            !require(std::fabs(b[2]) < 0.01 && b[3] > b[0] && b[4] > b[1] && b[5] > b[2],
                     "primitive is a positive solid on the bed")) return 4;
    }
    {
        std::unique_ptr<orca_session_t, decltype(&orca_session_destroy)>
            shape(orca_session_create(argv[2]), orca_session_destroy);
        float b[6]{};
        if (!require(orca_session_add_primitive(shape.get(), 0, 20, 10, 8) == 0, "scale fixture") ||
            !require(orca_session_translate_object(shape.get(), 0, 15, -7, 0) == 0, "off-center fixture") ||
            !require(orca_session_scale_object_axes(shape.get(), 0, 2, 3, 0.5) == 0, "axis scale") ||
            !require(orca_session_model_bounds(shape.get(), b, b+1, b+2, b+3, b+4, b+5) == 0, "scaled bounds") ||
            !require(std::fabs(b[3]-b[0]-40) < 0.01 && std::fabs(b[4]-b[1]-30) < 0.01 &&
                     std::fabs(b[5]-4) < 0.01 && std::fabs((b[0]+b[3])*0.5-125) < 0.01 &&
                     std::fabs((b[1]+b[4])*0.5-103) < 0.01, "scaled dimensions and stable center") ||
            !require(orca_session_scale_object_axes(shape.get(), 0, -1, 1, 1) != 0, "reject negative scale")) return 4;
    }
    for (const char *file : {"3DBenchy.drc", "calicat.drc", "OrcaCube_v2.drc", "OrcaPlug_v2.drc",
             "OrcaSliced.3mf", "OrcaBadge.3mf", "OrcaToleranceTest.drc", "ksr_fdmtest_v4.drc",
             "Voron_Design_Cube_v7.drc", "Stanford_Bunny.drc", "Orca_stringhell.drc"}) {
        std::unique_ptr<orca_session_t, decltype(&orca_session_destroy)>
            handy(orca_session_create(argv[2]), orca_session_destroy);
        const std::string path = std::string(argv[2]) + "/handy_models/" + file;
        if (!require(orca_session_add_model(handy.get(), path.c_str()) == 0, file) ||
            !require(orca_session_object_count(handy.get()) > 0, "handy model contains geometry")) return 4;
    }
    int scope = -1;
    if (!require(orca_session_option_presentation("layer_height", &scope) >= 0 && scope == 0, "process option ownership") ||
        !require(orca_session_option_presentation("filament_type", &scope) >= 0 && scope == 1, "filament option ownership") ||
        !require(orca_session_option_presentation("nozzle_diameter", &scope) >= 0 && scope == 2, "printer option ownership") ||
        !require(orca_session_option_presentation("missing_option", &scope) == -1, "unknown option is hidden"))
        return 4;
    if (!require(orca_session_set_option(session.get(), "post_process", "zmod-preprocess.py") == 0, "configure post-processing") ||
        !require(orca_session_post_process_count(session.get()) == 1, "post-processing command count") ||
        !require(std::string(orca_session_post_process_script(session.get(), 0)) == "zmod-preprocess.py", "desktop post-processing command") ||
        !require(orca_session_post_process_script(session.get(), 1) == nullptr, "post-processing command bounds") ||
        !require(orca_session_set_option(session.get(), "post_process", "") == 0, "disable post-processing"))
        return 4;
    std::ifstream nozzle_data(std::string(argv[2]) + "/info/nozzle_info.json");
    if (!require(nozzle_data.good(), "bundled nozzle data is available"))
        return 4;
    if (!require(orca_session_set_option(session.get(), "layer_height", "0.16") == 0, "set project layer height"))
        return 4;
    if (!require(orca_session_add_box(session.get(), "Smoke cube", 20, 20, 20) >= 0, "create cube") ||
        !require(orca_session_repair_mesh(session.get(), 0) == 0, "repair cube through current engine API") ||
        !require(orca_session_save_3mf(session.get(), project.c_str()) == 0, "save project") ||
        !require(orca_session_load_model(session.get(), project.c_str()) == 0, "import project"))
        return 4;
    char loaded_height[64]{};
    if (!require(orca_session_object_count(session.get()) == 1, "project retains its model") ||
        !require(orca_session_get_option(session.get(), "layer_height", loaded_height, sizeof(loaded_height)) == 0,
                 "read restored project setting") ||
        !require(std::fabs(std::strtof(loaded_height, nullptr) - 0.16f) < 0.0001f,
                 "project retains its layer height"))
        return 4;
    // A real Orca-format project uses the Bambu/Orca reader, unlike our legacy
    // store_3mf snapshot above. Model loading and project config need explicit flags.
    if (!require(orca_session_set_option(session.get(), "layer_height", "0.2") == 0, "reset layer height") ||
        !require(orca_session_load_model(session.get(), (directory + "/orca-project.3mf").c_str()) == 0,
                 "import Orca-format 3MF geometry") ||
        !require(orca_session_object_count(session.get()) == 1, "Orca project retains its object") ||
        !require(orca_session_get_option(session.get(), "layer_height", loaded_height, sizeof(loaded_height)) == 0,
                 "read Orca project settings") ||
        !require(std::fabs(std::strtof(loaded_height, nullptr) - 0.16f) < 0.0001f,
                 "Orca project restores layer height"))
        return 4;
    float before[6]{}, after[6]{};
    if (!require(orca_session_model_bounds(session.get(), &before[0], &before[1], &before[2], &before[3], &before[4], &before[5]) == 0, "read pre-rotation bounds") ||
        !require(orca_session_rotate_object_axis(session.get(), 0, 2, 90) == 0, "rotate imported object around Z") ||
        !require(orca_session_model_bounds(session.get(), &after[0], &after[1], &after[2], &after[3], &after[4], &after[5]) == 0, "read rotated bounds") ||
        !require(std::fabs(before[0] + before[3] - after[0] - after[3]) < 0.001f &&
                 std::fabs(before[1] + before[4] - after[1] - after[4]) < 0.001f, "rotation preserves the visible object center") ||
        !require(orca_session_rotate_object_axis(session.get(), 0, 2, -90) == 0, "restore object rotation"))
        return 4;
    const char *options[][2] = {
        {"use_relative_e_distances", "1"}, {"layer_change_gcode", "G92 E0"},
        {"layer_height", "0.2"}, {"wall_loops", "2"},
        {"sparse_infill_density", "15%"}, {"filament_diameter", "1.75"},
        {"nozzle_diameter", "0.4"}, {"printable_area", "0x0,220x0,220x220,0x220"},
        {"printable_height", "250"},
        // A stale 2-filament matrix with four active filaments reproduced the
        // mobile G-code export failure. Preserve its custom 100 mm³ pair.
        {"filament_colour", "#FF0000;#00FF00;#0000FF;#FFFFFF"},
        {"filament_diameter", "1.75,1.75,1.75,1.75"},
        {"flush_volumes_matrix", "0,100,100,0"}
    };
    for (const auto &option : options)
        if (!require(orca_session_set_option(session.get(), option[0], option[1]) == 0, option[0]))
            return 5;
    if (!require(orca_session_slice_to_gcode(session.get(), output.c_str()) == 0, "slice"))
        return 6;
    char flush[2048]{};
    if (!require(orca_session_get_option(session.get(), "flush_volumes_matrix", flush, sizeof(flush)) == 0,
                 "read repaired flush matrix")) return 6;
    int separators = 0;
    for (const char *p = flush; *p; ++p) if (*p == ',') ++separators;
    if (!require(separators == 15, "flush matrix matches four filaments") ||
        !require(std::string(flush).find("0,100,") == 0, "preserve existing custom purge volume")) return 6;
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
    bool has_height = false;
    for (size_t i = 0; i < count; ++i) {
        if (!require(std::isfinite(segments[i].end_z), "finite preview coordinates"))
            return 10;
        if (!segments[i].travel && segments[i].height > 0) has_height = true;
        if (!segments[i].travel && segments[i].end_z > max_z)
            max_z = segments[i].end_z;
    }
    if (!require(has_height, "preview includes processed bead height") || !require(max_z > 19.f, "preview reaches the top of the cube"))
        return 11;
    // A reader failure must leave the existing model/config/preview usable.
    const std::string broken = directory + "/broken.3mf";
    { std::ofstream invalid(broken); invalid << "not a 3MF archive"; }
    if (!require(orca_session_load_model(session.get(), broken.c_str()) != 0, "reject invalid 3MF") ||
        !require(orca_session_object_count(session.get()) == 1, "failed import preserves the previous model"))
        return 11;
    float previous_time = 0.f, previous_filament = 0.f;
    int previous_layers = 0;
    if (!require(orca_session_last_slice_stats(session.get(), &previous_time, &previous_filament, &previous_layers) == 0,
                 "failed import preserves valid slice statistics"))
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
    const std::string data_dir = directory + "/preset-catalog";
    if (!require(orca_session_set_data_dir(session.get(), data_dir.c_str()) == 0, "set preset data directory") ||
        !require(orca_session_load_all_presets(session.get()) == 0, "load official preset catalog") ||
        !require(orca_session_import_preset_catalog(session.get(), (directory + "/mobile-presets.orca_bundle").c_str()) == 2,
                 "import native printer and filament bundle") ||
        !require(orca_session_select_printer(session.get(), "iOS imported printer") == 0, "select imported printer") ||
        !require(orca_session_select_filament(session.get(), "iOS imported PLA") == 0, "select imported filament") ||
        !require(orca_session_import_cloud_presets(session.get(), (directory + "/cloud-presets.json").c_str(), "fixture-owner") == 2,
                 "import all cloud preset types") ||
        !require(orca_session_select_printer(session.get(), "iOS cloud printer") == 0, "select cloud printer") ||
        !require(orca_session_select_filament(session.get(), "iOS cloud PLA") == 0, "select cloud filament") ||
        !require(orca_session_export_user_profiles(session.get(), (directory + "/user-profile-export.json").c_str()) >= 4,
                 "export local and cloud profiles for sync"))
        return 16;
    if (!require(orca_session_preset_origin(session.get(), 2, "iOS cloud printer") == 2, "cloud printer ownership") ||
        !require(orca_session_preset_origin(session.get(), 1, "iOS cloud PLA") == 2, "cloud filament ownership") ||
        !require(orca_session_preset_origin(session.get(), 2, "iOS imported printer") == 1, "local printer ownership")) return 16;
    std::printf("PASS: primitives, centered axis scaling, flush matrix repair and processed preview height\n");
    std::printf("PASS: native preset bundle, cloud printer/filament catalog, selection and profile export\n");
    std::printf("PASS: 3MF import, slicing, G-code export, processed preview, validation, cancellation and recovery\n");
    return 0;
}
