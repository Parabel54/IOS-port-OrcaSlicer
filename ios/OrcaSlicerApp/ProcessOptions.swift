// Official OrcaSlicer process option enums (keys match PrintConfig.cpp).
// Used by process sheet pickers so values always serialize correctly.
// Also: searchable full settings browser over DynamicPrintConfig keys.

import Foundation
import SwiftUI

/// One selectable enum option: official serialize key + human label.
struct ProcessEnumChoice: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let label: String
}

/// One row in the full settings browser (from orca_session_option_*).
struct ConfigOptionEntry: Identifiable, Hashable {
    enum Kind: Int, Hashable {
        case bool = 0
        case int = 1
        case float = 2
        case percent = 3
        case string = 4
        case `enum` = 5
        case other = 6
    }

    var id: String { key }
    let key: String
    let scope: Int
    let mode: Int
    let label: String
    let category: String
    let sidetext: String
    let type: Kind
    var value: String
    let enumChoices: [ProcessEnumChoice]

    var displayCategory: String {
        category.isEmpty ? "Other" : category
    }
}

enum ProcessOptionCatalog {
    /// brim_type — s_keys_map_BrimType
    static let brimType: [ProcessEnumChoice] = [
        .init(key: "auto_brim", label: "Auto brim"),
        .init(key: "brim_ears", label: "Brim ears"),
        .init(key: "outer_only", label: "Outer only"),
        .init(key: "inner_only", label: "Inner only"),
        .init(key: "outer_and_inner", label: "Outer + inner"),
        .init(key: "painted", label: "Painted"),
        .init(key: "no_brim", label: "No brim"),
    ]

    /// support_type — s_keys_map_SupportType
    static let supportType: [ProcessEnumChoice] = [
        .init(key: "normal(auto)", label: "Normal (auto)"),
        .init(key: "tree(auto)", label: "Tree (auto)"),
        .init(key: "normal(manual)", label: "Normal (manual)"),
        .init(key: "tree(manual)", label: "Tree (manual)"),
    ]

    /// wall_generator — PerimeterGeneratorType
    static let wallGenerator: [ProcessEnumChoice] = [
        .init(key: "arachne", label: "Arachne"),
        .init(key: "classic", label: "Classic"),
    ]

    /// seam_position — s_keys_map_SeamPosition
    static let seamPosition: [ProcessEnumChoice] = [
        .init(key: "aligned", label: "Aligned"),
        .init(key: "aligned_back", label: "Aligned back"),
        .init(key: "nearest", label: "Nearest"),
        .init(key: "back", label: "Back"),
        .init(key: "random", label: "Random"),
    ]

    /// ironing_type — NOT a bool; key is ironing_type
    static let ironingType: [ProcessEnumChoice] = [
        .init(key: "no ironing", label: "No ironing"),
        .init(key: "top", label: "Top surfaces"),
        .init(key: "topmost", label: "Topmost only"),
        .init(key: "solid", label: "All solid"),
    ]

    /// sparse_infill_pattern (common subset)
    static let infillPattern: [ProcessEnumChoice] = [
        .init(key: "grid", label: "Grid"),
        .init(key: "line", label: "Line"),
        .init(key: "triangles", label: "Triangles"),
        .init(key: "trihexagon", label: "Tri-hexagon"),
        .init(key: "cubic", label: "Cubic"),
        .init(key: "adaptivecubic", label: "Adaptive cubic"),
        .init(key: "quartercubic", label: "Quarter cubic"),
        .init(key: "supportcubic", label: "Support cubic"),
        .init(key: "lightning", label: "Lightning"),
        .init(key: "gyroid", label: "Gyroid"),
        .init(key: "honeycomb", label: "Honeycomb"),
        .init(key: "3dhoneycomb", label: "3D honeycomb"),
        .init(key: "hilbertcurve", label: "Hilbert curve"),
        .init(key: "archimedeanchords", label: "Archimedean chords"),
        .init(key: "octagramspiral", label: "Octagram spiral"),
        .init(key: "crosshatch", label: "Cross hatch"),
    ]

    static func label(for key: String, in choices: [ProcessEnumChoice]) -> String {
        choices.first { $0.key == key }?.label ?? key
    }

    /// Match engine value to a known choice key (handles spacing / case quirks).
    static func match(_ raw: String?, in choices: [ProcessEnumChoice], fallback: String) -> String {
        guard let raw, !raw.isEmpty else { return fallback }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if choices.contains(where: { $0.key == t }) { return t }
        if let hit = choices.first(where: { $0.key.caseInsensitiveCompare(t) == .orderedSame }) {
            return hit.key
        }
        // Sometimes serialized with underscores vs spaces
        let norm = t.replacingOccurrences(of: "_", with: " ")
        if let hit = choices.first(where: { $0.key == norm }) { return hit.key }
        return fallback
    }
}

extension OrcaEngine {
    /// First scalar of a multi-value option (temps, diameters often "210,210").
    func getOptionFirst(_ key: String) -> String? {
        guard let v = getOption(key) else { return nil }
        let first = v.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? v
        return first.isEmpty ? nil : first
    }

    /// Percent options may serialize as "15%" — strip for text fields.
    func getOptionPercent(_ key: String) -> String? {
        guard let v = getOptionFirst(key) else { return nil }
        return v.replacingOccurrences(of: "%", with: "")
    }

    /// Bool option: true for 1/true/yes.
    func getOptionBool(_ key: String) -> Bool {
        guard let v = getOptionFirst(key)?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    /// Set a scalar; for multi-value filament keys write a single-element string.
    func setOptionScalar(_ key: String, value: String) {
        setOption(key, value: value)
    }

    /// Set percent option (accepts "15" or "15%").
    func setOptionPercent(_ key: String, value: String) {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.hasSuffix("%") { v += "%" }
        setOption(key, value: v)
    }

    func setOptionBool(_ key: String, value: Bool) {
        setOption(key, value: value ? "1" : "0")
    }
}

// MARK: - Searchable full settings browser

/// Browse / edit every DynamicPrintConfig key via official serialize strings.
struct ProcessSettingsBrowser: View {
    @ObservedObject var engine: OrcaEngine
    var onChanged: (() -> Void)?
    @State private var scope = 0
    @State private var mode = 0
    @State private var presetSearch = ""
    @State private var saveName = ""
    @State private var savePreset = false

    @State private var entries: [ConfigOptionEntry] = []
    @State private var search = ""
    @State private var categoryFilter = ""
    @State private var draftValues: [String: String] = [:]
    @State private var applyError: String?
    @State private var isLoading = true

    private let themeBg = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    private let themePanel = Color(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3C / 255.0)
    private let themeAccent = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    private let themeMuted = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB5 / 255.0)
    private let themeText = Color(red: 0xEF / 255.0, green: 0xEF / 255.0, blue: 0xF0 / 255.0)
    private let themeField = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)

    private var categories: [String] {
        let scoped = entries.filter { $0.scope == scope && $0.mode <= mode }
        return Array(Set(scoped.map { DesktopSettings.location($0).page })).sorted {
            DesktopSettings.pageOrder($0, scope: scope) < DesktopSettings.pageOrder($1, scope: scope)
        }
    }

    private var filtered: [ConfigOptionEntry] {
        var list = entries.filter { $0.scope == scope && $0.mode <= mode && $0.key != "post_process" }
        if !categoryFilter.isEmpty {
            list = list.filter { DesktopSettings.location($0).page == categoryFilter }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.key.lowercased().contains(q)
                    || $0.label.lowercased().contains(q)
                    || $0.category.lowercased().contains(q)
                    || $0.value.lowercased().contains(q)
            }
        }
        return list
    }

    private var grouped: [(String, [ConfigOptionEntry])] {
        let ordered = filtered.sorted { DesktopSettings.location($0).order < DesktopSettings.location($1).order }
        var groups: [(String, [ConfigOptionEntry])] = []
        for entry in ordered {
            let place = DesktopSettings.location(entry)
            let title = place.page + " · " + place.group
            if let index = groups.firstIndex(where: { $0.0 == title }) { groups[index].1.append(entry) }
            else { groups.append((title, [entry])) }
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings scope", selection: $scope) {
                    Text("Printer").tag(2)
                    Text("Filament").tag(1)
                    Text("Process").tag(0)
                }.pickerStyle(.segmented).padding(8)
                Picker("Setting visibility", selection: $mode) {
                    Text("Basic").tag(0)
                    Text("Advanced").tag(1)
                    Text("Expert").tag(2)
                }.pickerStyle(.segmented).padding(.horizontal, 8)
                presetSelector
                if isLoading {
                    ProgressView("Loading options…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(themeMuted)
                } else {
                    if !categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                catChip("All", selected: categoryFilter.isEmpty) {
                                    categoryFilter = ""
                                }
                                ForEach(categories, id: \.self) { c in
                                    catChip(c, selected: categoryFilter == c) {
                                        categoryFilter = c
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .background(themePanel)
                    }
                    if let applyError {
                        Text(applyError)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0xBB / 255.0, green: 0x2A / 255.0, blue: 0x3A / 255.0))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(themePanel)
                    }
                    List {
                        if scope == 0 && (categoryFilter.isEmpty || categoryFilter == "Others") {
                            NavigationLink("Post-processing plugins") { NativeProcessingPanel(engine: engine) }
                        }
                        Text("\(filtered.count) of \(entries.count) options")
                            .font(.caption)
                            .foregroundStyle(themeMuted)
                            .listRowBackground(themePanel)
                        ForEach(grouped, id: \.0) { cat, rows in
                            Section(cat) {
                                ForEach(rows) { entry in
                                    optionRow(entry)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(themeBg)
            .searchable(text: $search, prompt: "Search key, label, value")
            .navigationTitle("Print settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Reload") { reload() }
                        if scope != 2 { Button("Save preset as…") { savePreset = true } }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .foregroundStyle(themeAccent)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear { reload() }
            .onChange(of: scope) { _ in categoryFilter = ""; presetSearch = "" }
            .onChange(of: engine.selectedPrinter) { _ in reload() }
            .onChange(of: engine.selectedFilament) { _ in reload() }
            .onChange(of: engine.selectedProcess) { _ in reload() }
            .alert("Save preset as", isPresented: $savePreset) {
                TextField("Preset name", text: $saveName)
                Button("Save") {
                    let ok = scope == 1 ? engine.saveUserFilament(name: saveName) : engine.saveUserProcess(name: saveName)
                    if !ok { applyError = engine.lastMessage }
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var presetSelector: some View {
        let names = scope == 2 ? engine.printerNames : scope == 1 ? engine.filamentNames : engine.processNames
        let selected = scope == 2 ? engine.selectedPrinter : scope == 1 ? engine.selectedFilament : engine.selectedProcess
        return NavigationLink {
            List(names.filter { presetSearch.isEmpty || $0.localizedCaseInsensitiveContains(presetSearch) }, id: \.self) { name in
                Button {
                    let ok = scope == 2 ? engine.selectPrinter(name) : scope == 1 ? engine.selectFilament(name) : engine.selectProcess(name)
                    if !ok { applyError = engine.lastMessage }
                    reload()
                    onChanged?()
                } label: {
                    HStack { Text(name); Spacer(); if name == selected { Image(systemName: "checkmark") } }
                }
            }.searchable(text: $presetSearch, prompt: "Search presets")
                .navigationTitle("Select preset")
        } label: {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text(selected.isEmpty ? "Select preset" : selected).lineLimit(2)
                Spacer()
                Image(systemName: "chevron.right")
            }.font(.subheadline).frame(minHeight: 44).padding(.horizontal, 12)
        }.disabled(engine.presetsLoading)
    }

    private func catChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? themeAccent.opacity(0.25) : themeField)
                .foregroundStyle(selected ? themeAccent : themeMuted)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionRow(_ entry: ConfigOptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeText)
                    .lineLimit(2)
                Spacer()
                if !entry.sidetext.isEmpty {
                    Text(entry.sidetext)
                        .font(.system(size: 11))
                        .foregroundStyle(themeMuted)
                }
            }
            Text(entry.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(themeMuted)
                .lineLimit(1)

            switch entry.type {
            case .bool:
                Toggle(isOn: Binding(
                    get: {
                        let v = (draftValues[entry.key] ?? entry.value).lowercased()
                        return v == "1" || v == "true" || v == "yes" || v == "on"
                    },
                    set: { on in
                        apply(entry.key, value: on ? "1" : "0")
                    }
                )) {
                    Text("enabled").font(.system(size: 12)).foregroundStyle(themeMuted)
                }
                .tint(themeAccent)

            case .enum:
                // Lazy enum lists: filled on first display via engine.enumChoices
                let choices: [ProcessEnumChoice] = {
                    if !entry.enumChoices.isEmpty { return entry.enumChoices }
                    return engine.enumChoices(for: entry.key)
                }()
                if !choices.isEmpty {
                    let current = draftValues[entry.key] ?? entry.value
                    let matched = ProcessOptionCatalog.match(
                        current, in: choices, fallback: choices[0].key
                    )
                    Picker(entry.key, selection: Binding(
                        get: { matched },
                        set: { apply(entry.key, value: $0) }
                    )) {
                        ForEach(choices) { c in
                            Text(c.label).tag(c.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(themeAccent)
                } else {
                    scalarEditor(entry)
                }

            default:
                scalarEditor(entry)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(themePanel)
    }

    private func scalarEditor(_ entry: ConfigOptionEntry) -> some View {
        let draft = Binding<String>(
            get: { draftValues[entry.key] ?? entry.value },
            set: { draftValues[entry.key] = $0 }
        )
        return HStack(spacing: 8) {
            TextField(entry.key, text: draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(themeText)
                .padding(8)
                .background(themeField)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Apply") {
                apply(entry.key, value: draftValues[entry.key] ?? entry.value)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(themeAccent)
        }
    }

    private func apply(_ key: String, value: String) {
        let ok = engine.applyConfigOption(key: key, value: value)
        if ok {
            applyError = nil
            draftValues[key] = value
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                entries[idx].value = value
            }
            onChanged?()
        } else {
            applyError = engine.lastMessage
        }
    }

    private func reload() {
        isLoading = true
        applyError = nil
        // Session C ABI is not thread-safe; snapshot on main (hundreds of keys is fine).
        let snap = engine.allConfigOptions()
        var drafts: [String: String] = [:]
        for e in snap { drafts[e.key] = e.value }
        entries = snap
        draftValues = drafts
        isLoading = false
    }
}

// Generated from desktop Tab.cpp; regenerate with scripts/generate_ios_settings.py.
enum DesktopSettings {
    struct Location { let page: String; let group: String; let order: Int }
    static func location(_ entry: ConfigOptionEntry) -> Location {
        locations["\(entry.scope):\(entry.key)"] ?? Location(page: entry.displayCategory, group: "Additional settings", order: 10000)
    }
    static func pageOrder(_ page: String, scope: Int) -> Int {
        pages[scope]?.firstIndex(of: page) ?? 10000
    }
    static let pages: [Int: [String]] = [
        0: ["Quality", "Strength", "Speed", "Support", "Multimaterial", "Others"],
        1: ["Filament", "Cooling", "Advanced", "Multimaterial", "Dependencies", "Notes"],
        2: ["Basic information", "Machine G-code", "Notes", "Motion ability", "Multimaterial", "Extruder"],
    ]
    static let locations: [String: Location] = [
        "0:layer_height": Location(page: "Quality", group: "Layer height", order: 0),
        "0:initial_layer_print_height": Location(page: "Quality", group: "Layer height", order: 1),
        "0:enable_mixed_color_sublayer": Location(page: "Quality", group: "Layer height", order: 2),
        "0:line_width": Location(page: "Quality", group: "Line width", order: 3),
        "0:initial_layer_line_width": Location(page: "Quality", group: "Line width", order: 4),
        "0:outer_wall_line_width": Location(page: "Quality", group: "Line width", order: 5),
        "0:inner_wall_line_width": Location(page: "Quality", group: "Line width", order: 6),
        "0:top_surface_line_width": Location(page: "Quality", group: "Line width", order: 7),
        "0:sparse_infill_line_width": Location(page: "Quality", group: "Line width", order: 8),
        "0:internal_solid_infill_line_width": Location(page: "Quality", group: "Line width", order: 9),
        "0:support_line_width": Location(page: "Quality", group: "Line width", order: 10),
        "0:bridge_line_width": Location(page: "Quality", group: "Line width", order: 11),
        "0:seam_position": Location(page: "Quality", group: "Seam", order: 12),
        "0:staggered_inner_seams": Location(page: "Quality", group: "Seam", order: 13),
        "0:seam_gap": Location(page: "Quality", group: "Seam", order: 14),
        "0:seam_slope_type": Location(page: "Quality", group: "Seam", order: 15),
        "0:seam_slope_conditional": Location(page: "Quality", group: "Seam", order: 16),
        "0:scarf_angle_threshold": Location(page: "Quality", group: "Seam", order: 17),
        "0:scarf_overhang_threshold": Location(page: "Quality", group: "Seam", order: 18),
        "0:scarf_joint_speed": Location(page: "Quality", group: "Seam", order: 19),
        "0:seam_slope_start_height": Location(page: "Quality", group: "Seam", order: 20),
        "0:seam_slope_entire_loop": Location(page: "Quality", group: "Seam", order: 21),
        "0:seam_slope_min_length": Location(page: "Quality", group: "Seam", order: 22),
        "0:seam_slope_steps": Location(page: "Quality", group: "Seam", order: 23),
        "0:scarf_joint_flow_ratio": Location(page: "Quality", group: "Seam", order: 24),
        "0:seam_slope_inner_walls": Location(page: "Quality", group: "Seam", order: 25),
        "0:role_based_wipe_speed": Location(page: "Quality", group: "Seam", order: 26),
        "0:wipe_speed": Location(page: "Quality", group: "Seam", order: 27),
        "0:wipe_on_loops": Location(page: "Quality", group: "Seam", order: 28),
        "0:wipe_inward": Location(page: "Quality", group: "Seam", order: 29),
        "0:wipe_inward_distance": Location(page: "Quality", group: "Seam", order: 30),
        "0:wipe_before_external_loop": Location(page: "Quality", group: "Seam", order: 31),
        "0:slice_closing_radius": Location(page: "Quality", group: "Precision", order: 32),
        "0:resolution": Location(page: "Quality", group: "Precision", order: 33),
        "0:enable_arc_fitting": Location(page: "Quality", group: "Precision", order: 34),
        "0:xy_hole_compensation": Location(page: "Quality", group: "Precision", order: 35),
        "0:xy_contour_compensation": Location(page: "Quality", group: "Precision", order: 36),
        "0:elefant_foot_compensation": Location(page: "Quality", group: "Precision", order: 37),
        "0:elefant_foot_layers_density": Location(page: "Quality", group: "Precision", order: 38),
        "0:elefant_foot_compensation_layers": Location(page: "Quality", group: "Precision", order: 39),
        "0:precise_outer_wall": Location(page: "Quality", group: "Precision", order: 40),
        "0:precise_z_height": Location(page: "Quality", group: "Precision", order: 41),
        "0:hole_to_polyhole": Location(page: "Quality", group: "Precision", order: 42),
        "0:hole_to_polyhole_threshold": Location(page: "Quality", group: "Precision", order: 43),
        "0:hole_to_polyhole_twisted": Location(page: "Quality", group: "Precision", order: 44),
        "0:hole_to_polyhole_max_edges": Location(page: "Quality", group: "Precision", order: 45),
        "0:ironing_type": Location(page: "Quality", group: "Ironing", order: 46),
        "0:ironing_pattern": Location(page: "Quality", group: "Ironing", order: 47),
        "0:ironing_flow": Location(page: "Quality", group: "Ironing", order: 48),
        "0:ironing_spacing": Location(page: "Quality", group: "Ironing", order: 49),
        "0:ironing_inset": Location(page: "Quality", group: "Ironing", order: 50),
        "0:ironing_angle": Location(page: "Quality", group: "Ironing", order: 51),
        "0:ironing_angle_fixed": Location(page: "Quality", group: "Ironing", order: 52),
        "0:zaa_enabled": Location(page: "Quality", group: "Z contouring", order: 53),
        "0:zaa_minimize_perimeter_height": Location(page: "Quality", group: "Z contouring", order: 54),
        "0:zaa_min_z": Location(page: "Quality", group: "Z contouring", order: 55),
        "0:zaa_dont_alternate_fill_direction": Location(page: "Quality", group: "Z contouring", order: 56),
        "0:wall_generator": Location(page: "Quality", group: "Wall generator", order: 57),
        "0:wall_transition_angle": Location(page: "Quality", group: "Wall generator", order: 58),
        "0:wall_transition_filter_deviation": Location(page: "Quality", group: "Wall generator", order: 59),
        "0:wall_transition_length": Location(page: "Quality", group: "Wall generator", order: 60),
        "0:wall_distribution_count": Location(page: "Quality", group: "Wall generator", order: 61),
        "0:initial_layer_min_bead_width": Location(page: "Quality", group: "Wall generator", order: 62),
        "0:min_bead_width": Location(page: "Quality", group: "Wall generator", order: 63),
        "0:min_feature_size": Location(page: "Quality", group: "Wall generator", order: 64),
        "0:min_length_factor": Location(page: "Quality", group: "Wall generator", order: 65),
        "0:wall_maximum_resolution": Location(page: "Quality", group: "Wall generator", order: 66),
        "0:wall_maximum_deviation": Location(page: "Quality", group: "Wall generator", order: 67),
        "0:wall_sequence": Location(page: "Quality", group: "Walls and surfaces", order: 68),
        "0:is_infill_first": Location(page: "Quality", group: "Walls and surfaces", order: 69),
        "0:wall_direction": Location(page: "Quality", group: "Walls and surfaces", order: 70),
        "0:print_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 71),
        "0:top_solid_infill_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 72),
        "0:bottom_solid_infill_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 73),
        "0:set_other_flow_ratios": Location(page: "Quality", group: "Walls and surfaces", order: 74),
        "0:first_layer_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 75),
        "0:outer_wall_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 76),
        "0:inner_wall_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 77),
        "0:overhang_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 78),
        "0:sparse_infill_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 79),
        "0:internal_solid_infill_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 80),
        "0:gap_fill_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 81),
        "0:support_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 82),
        "0:support_interface_flow_ratio": Location(page: "Quality", group: "Walls and surfaces", order: 83),
        "0:only_one_wall_first_layer": Location(page: "Quality", group: "Walls and surfaces", order: 84),
        "0:only_one_wall_top": Location(page: "Quality", group: "Walls and surfaces", order: 85),
        "0:min_width_top_surface": Location(page: "Quality", group: "Walls and surfaces", order: 86),
        "0:reduce_crossing_wall": Location(page: "Quality", group: "Walls and surfaces", order: 87),
        "0:max_travel_detour_distance": Location(page: "Quality", group: "Walls and surfaces", order: 88),
        "0:small_area_infill_flow_compensation": Location(page: "Quality", group: "Walls and surfaces", order: 89),
        "0:small_area_infill_flow_compensation_model": Location(page: "Quality", group: "Walls and surfaces", order: 90),
        "0:bridge_flow": Location(page: "Quality", group: "Bridging", order: 91),
        "0:internal_bridge_flow": Location(page: "Quality", group: "Bridging", order: 92),
        "0:bridge_density": Location(page: "Quality", group: "Bridging", order: 93),
        "0:internal_bridge_density": Location(page: "Quality", group: "Bridging", order: 94),
        "0:thick_bridges": Location(page: "Quality", group: "Bridging", order: 95),
        "0:thick_internal_bridges": Location(page: "Quality", group: "Bridging", order: 96),
        "0:enable_extra_bridge_layer": Location(page: "Quality", group: "Bridging", order: 97),
        "0:dont_filter_internal_bridges": Location(page: "Quality", group: "Bridging", order: 98),
        "0:counterbore_hole_bridging": Location(page: "Quality", group: "Bridging", order: 99),
        "0:detect_overhang_wall": Location(page: "Quality", group: "Overhangs", order: 100),
        "0:unsupported_wall_last": Location(page: "Quality", group: "Overhangs", order: 101),
        "0:make_overhang_printable": Location(page: "Quality", group: "Overhangs", order: 102),
        "0:make_overhang_printable_angle": Location(page: "Quality", group: "Overhangs", order: 103),
        "0:make_overhang_printable_hole_size": Location(page: "Quality", group: "Overhangs", order: 104),
        "0:extra_perimeters_on_overhangs": Location(page: "Quality", group: "Overhangs", order: 105),
        "0:overhang_reverse": Location(page: "Quality", group: "Overhangs", order: 106),
        "0:overhang_reverse_internal_only": Location(page: "Quality", group: "Overhangs", order: 107),
        "0:overhang_reverse_threshold": Location(page: "Quality", group: "Overhangs", order: 108),
        "0:wall_loops": Location(page: "Strength", group: "Walls", order: 109),
        "0:alternate_extra_wall": Location(page: "Strength", group: "Walls", order: 110),
        "0:detect_thin_wall": Location(page: "Strength", group: "Walls", order: 111),
        "0:top_shell_layers": Location(page: "Strength", group: "Top/bottom shells", order: 112),
        "0:top_shell_thickness": Location(page: "Strength", group: "Top/bottom shells", order: 113),
        "0:top_color_penetration_layers": Location(page: "Strength", group: "Top/bottom shells", order: 114),
        "0:top_surface_density": Location(page: "Strength", group: "Top/bottom shells", order: 115),
        "0:top_surface_pattern": Location(page: "Strength", group: "Top/bottom shells", order: 116),
        "0:top_surface_fill_order": Location(page: "Strength", group: "Top/bottom shells", order: 117),
        "0:top_layer_direction": Location(page: "Strength", group: "Top/bottom shells", order: 118),
        "0:top_surface_expansion": Location(page: "Strength", group: "Top/bottom shells", order: 119),
        "0:top_surface_expansion_margin": Location(page: "Strength", group: "Top/bottom shells", order: 120),
        "0:top_surface_expansion_direction": Location(page: "Strength", group: "Top/bottom shells", order: 121),
        "0:bottom_shell_layers": Location(page: "Strength", group: "Top/bottom shells", order: 122),
        "0:bottom_shell_thickness": Location(page: "Strength", group: "Top/bottom shells", order: 123),
        "0:bottom_color_penetration_layers": Location(page: "Strength", group: "Top/bottom shells", order: 124),
        "0:bottom_surface_density": Location(page: "Strength", group: "Top/bottom shells", order: 125),
        "0:bottom_surface_pattern": Location(page: "Strength", group: "Top/bottom shells", order: 126),
        "0:bottom_surface_fill_order": Location(page: "Strength", group: "Top/bottom shells", order: 127),
        "0:bottom_layer_direction": Location(page: "Strength", group: "Top/bottom shells", order: 128),
        "0:center_of_surface_pattern": Location(page: "Strength", group: "Top/bottom shells", order: 129),
        "0:top_bottom_infill_wall_overlap": Location(page: "Strength", group: "Top/bottom shells", order: 130),
        "0:sparse_infill_density": Location(page: "Strength", group: "Infill", order: 131),
        "0:fill_multiline": Location(page: "Strength", group: "Infill", order: 132),
        "0:sparse_infill_pattern": Location(page: "Strength", group: "Infill", order: 133),
        "0:adaptive_infill_mode": Location(page: "Strength", group: "Infill", order: 134),
        "0:adaptive_infill_interior_density": Location(page: "Strength", group: "Infill", order: 135),
        "0:adaptive_infill_gradient": Location(page: "Strength", group: "Infill", order: 136),
        "0:gyroid_optimized": Location(page: "Strength", group: "Infill", order: 137),
        "0:sparse_infill_smooth_factor": Location(page: "Strength", group: "Infill", order: 138),
        "0:infill_direction": Location(page: "Strength", group: "Infill", order: 139),
        "0:sparse_infill_rotate_template": Location(page: "Strength", group: "Infill", order: 140),
        "0:skin_infill_density": Location(page: "Strength", group: "Infill", order: 141),
        "0:skeleton_infill_density": Location(page: "Strength", group: "Infill", order: 142),
        "0:infill_lock_depth": Location(page: "Strength", group: "Infill", order: 143),
        "0:skin_infill_depth": Location(page: "Strength", group: "Infill", order: 144),
        "0:skin_infill_line_width": Location(page: "Strength", group: "Infill", order: 145),
        "0:skeleton_infill_line_width": Location(page: "Strength", group: "Infill", order: 146),
        "0:symmetric_infill_y_axis": Location(page: "Strength", group: "Infill", order: 147),
        "0:infill_complete_top": Location(page: "Strength", group: "Infill", order: 148),
        "0:infill_shift_step": Location(page: "Strength", group: "Infill", order: 149),
        "0:lateral_lattice_angle_1": Location(page: "Strength", group: "Infill", order: 150),
        "0:lateral_lattice_angle_2": Location(page: "Strength", group: "Infill", order: 151),
        "0:infill_overhang_angle": Location(page: "Strength", group: "Infill", order: 152),
        "0:lightning_overhang_angle": Location(page: "Strength", group: "Infill", order: 153),
        "0:lightning_prune_angle": Location(page: "Strength", group: "Infill", order: 154),
        "0:lightning_straightening_angle": Location(page: "Strength", group: "Infill", order: 155),
        "0:infill_anchor_max": Location(page: "Strength", group: "Infill", order: 156),
        "0:infill_anchor": Location(page: "Strength", group: "Infill", order: 157),
        "0:internal_solid_infill_pattern": Location(page: "Strength", group: "Infill", order: 158),
        "0:solid_infill_direction": Location(page: "Strength", group: "Infill", order: 159),
        "0:solid_infill_rotate_template": Location(page: "Strength", group: "Infill", order: 160),
        "0:gap_fill_target": Location(page: "Strength", group: "Infill", order: 161),
        "0:filter_out_gap_fill": Location(page: "Strength", group: "Infill", order: 162),
        "0:separated_infills": Location(page: "Strength", group: "Infill", order: 163),
        "0:infill_wall_overlap": Location(page: "Strength", group: "Infill", order: 164),
        "0:align_infill_direction_to_model": Location(page: "Strength", group: "Advanced", order: 165),
        "0:extra_solid_infills": Location(page: "Strength", group: "Advanced", order: 166),
        "0:bridge_angle": Location(page: "Strength", group: "Advanced", order: 167),
        "0:internal_bridge_angle": Location(page: "Strength", group: "Advanced", order: 168),
        "0:relative_bridge_angle": Location(page: "Strength", group: "Advanced", order: 169),
        "0:minimum_sparse_infill_area": Location(page: "Strength", group: "Advanced", order: 170),
        "0:infill_combination": Location(page: "Strength", group: "Advanced", order: 171),
        "0:infill_combination_max_layer_height": Location(page: "Strength", group: "Advanced", order: 172),
        "0:detect_narrow_internal_solid_infill": Location(page: "Strength", group: "Advanced", order: 173),
        "0:ensure_vertical_shell_thickness": Location(page: "Strength", group: "Advanced", order: 174),
        "0:initial_layer_speed": Location(page: "Speed", group: "First layer speed", order: 175),
        "0:initial_layer_infill_speed": Location(page: "Speed", group: "First layer speed", order: 176),
        "0:initial_layer_travel_speed": Location(page: "Speed", group: "First layer speed", order: 177),
        "0:slow_down_layers": Location(page: "Speed", group: "First layer speed", order: 178),
        "0:outer_wall_speed": Location(page: "Speed", group: "Other layers speed", order: 179),
        "0:inner_wall_speed": Location(page: "Speed", group: "Other layers speed", order: 180),
        "0:small_perimeter_speed": Location(page: "Speed", group: "Other layers speed", order: 181),
        "0:small_perimeter_threshold": Location(page: "Speed", group: "Other layers speed", order: 182),
        "0:sparse_infill_speed": Location(page: "Speed", group: "Other layers speed", order: 183),
        "0:internal_solid_infill_speed": Location(page: "Speed", group: "Other layers speed", order: 184),
        "0:top_surface_speed": Location(page: "Speed", group: "Other layers speed", order: 185),
        "0:gap_infill_speed": Location(page: "Speed", group: "Other layers speed", order: 186),
        "0:ironing_speed": Location(page: "Speed", group: "Other layers speed", order: 187),
        "0:support_speed": Location(page: "Speed", group: "Other layers speed", order: 188),
        "0:support_interface_speed": Location(page: "Speed", group: "Other layers speed", order: 189),
        "0:small_support_perimeter_speed": Location(page: "Speed", group: "Other layers speed", order: 190),
        "0:small_support_perimeter_threshold": Location(page: "Speed", group: "Other layers speed", order: 191),
        "0:enable_overhang_speed": Location(page: "Speed", group: "Overhang speed", order: 192),
        "0:slowdown_for_curled_perimeters": Location(page: "Speed", group: "Overhang speed", order: 193),
        "0:overhang_1_4_speed": Location(page: "Speed", group: "Overhang speed", order: 194),
        "0:overhang_2_4_speed": Location(page: "Speed", group: "Overhang speed", order: 195),
        "0:overhang_3_4_speed": Location(page: "Speed", group: "Overhang speed", order: 196),
        "0:overhang_4_4_speed": Location(page: "Speed", group: "Overhang speed", order: 197),
        "0:bridge_speed": Location(page: "Speed", group: "Overhang speed", order: 198),
        "0:internal_bridge_speed": Location(page: "Speed", group: "Overhang speed", order: 199),
        "0:travel_speed": Location(page: "Speed", group: "Travel speed", order: 200),
        "0:default_acceleration": Location(page: "Speed", group: "Acceleration", order: 201),
        "0:outer_wall_acceleration": Location(page: "Speed", group: "Acceleration", order: 202),
        "0:inner_wall_acceleration": Location(page: "Speed", group: "Acceleration", order: 203),
        "0:bridge_acceleration": Location(page: "Speed", group: "Acceleration", order: 204),
        "0:sparse_infill_acceleration": Location(page: "Speed", group: "Acceleration", order: 205),
        "0:internal_solid_infill_acceleration": Location(page: "Speed", group: "Acceleration", order: 206),
        "0:initial_layer_acceleration": Location(page: "Speed", group: "Acceleration", order: 207),
        "0:initial_layer_travel_acceleration": Location(page: "Speed", group: "Acceleration", order: 208),
        "0:top_surface_acceleration": Location(page: "Speed", group: "Acceleration", order: 209),
        "0:travel_acceleration": Location(page: "Speed", group: "Acceleration", order: 210),
        "0:accel_to_decel_enable": Location(page: "Speed", group: "Acceleration", order: 211),
        "0:accel_to_decel_factor": Location(page: "Speed", group: "Acceleration", order: 212),
        "0:default_junction_deviation": Location(page: "Speed", group: "Junction Deviation", order: 213),
        "0:default_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 214),
        "0:outer_wall_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 215),
        "0:inner_wall_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 216),
        "0:infill_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 217),
        "0:top_surface_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 218),
        "0:initial_layer_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 219),
        "0:initial_layer_travel_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 220),
        "0:travel_jerk": Location(page: "Speed", group: "Jerk(XY)", order: 221),
        "0:max_volumetric_extrusion_rate_slope": Location(page: "Speed", group: "Advanced", order: 222),
        "0:max_volumetric_extrusion_rate_slope_segment_length": Location(page: "Speed", group: "Advanced", order: 223),
        "0:extrusion_rate_smoothing_external_perimeter_only": Location(page: "Speed", group: "Advanced", order: 224),
        "0:enable_support": Location(page: "Support", group: "Support", order: 225),
        "0:support_type": Location(page: "Support", group: "Support", order: 226),
        "0:support_style": Location(page: "Support", group: "Support", order: 227),
        "0:support_threshold_angle": Location(page: "Support", group: "Support", order: 228),
        "0:support_threshold_overlap": Location(page: "Support", group: "Support", order: 229),
        "0:raft_first_layer_density": Location(page: "Support", group: "Support", order: 230),
        "0:raft_first_layer_expansion": Location(page: "Support", group: "Support", order: 231),
        "0:support_on_build_plate_only": Location(page: "Support", group: "Support", order: 232),
        "0:support_critical_regions_only": Location(page: "Support", group: "Support", order: 233),
        "0:support_remove_small_overhang": Location(page: "Support", group: "Support", order: 234),
        "0:raft_layers": Location(page: "Support", group: "Raft", order: 235),
        "0:raft_contact_distance": Location(page: "Support", group: "Raft", order: 236),
        "0:raft_expansion": Location(page: "Support", group: "Raft", order: 237),
        "0:support_filament": Location(page: "Support", group: "Filament for Supports", order: 238),
        "0:support_interface_filament": Location(page: "Support", group: "Filament for Supports", order: 239),
        "0:support_interface_not_for_body": Location(page: "Support", group: "Filament for Supports", order: 240),
        "0:support_ironing": Location(page: "Support", group: "Support ironing", order: 241),
        "0:support_ironing_pattern": Location(page: "Support", group: "Support ironing", order: 242),
        "0:support_ironing_flow": Location(page: "Support", group: "Support ironing", order: 243),
        "0:support_ironing_spacing": Location(page: "Support", group: "Support ironing", order: 244),
        "0:support_top_z_distance": Location(page: "Support", group: "Advanced", order: 245),
        "0:support_bottom_z_distance": Location(page: "Support", group: "Advanced", order: 246),
        "0:tree_support_wall_count": Location(page: "Support", group: "Advanced", order: 247),
        "0:support_base_pattern": Location(page: "Support", group: "Advanced", order: 248),
        "0:support_base_pattern_spacing": Location(page: "Support", group: "Advanced", order: 249),
        "0:support_angle": Location(page: "Support", group: "Advanced", order: 250),
        "0:support_interface_top_layers": Location(page: "Support", group: "Advanced", order: 251),
        "0:support_interface_bottom_layers": Location(page: "Support", group: "Advanced", order: 252),
        "0:support_interface_pattern": Location(page: "Support", group: "Advanced", order: 253),
        "0:support_interface_spacing": Location(page: "Support", group: "Advanced", order: 254),
        "0:support_bottom_interface_spacing": Location(page: "Support", group: "Advanced", order: 255),
        "0:support_expansion": Location(page: "Support", group: "Advanced", order: 256),
        "0:support_object_xy_distance": Location(page: "Support", group: "Advanced", order: 257),
        "0:support_object_first_layer_gap": Location(page: "Support", group: "Advanced", order: 258),
        "0:bridge_no_support": Location(page: "Support", group: "Advanced", order: 259),
        "0:max_bridge_length": Location(page: "Support", group: "Advanced", order: 260),
        "0:independent_support_layer_height": Location(page: "Support", group: "Advanced", order: 261),
        "0:tree_support_tip_diameter": Location(page: "Support", group: "Tree supports", order: 262),
        "0:tree_support_branch_distance": Location(page: "Support", group: "Tree supports", order: 263),
        "0:tree_support_branch_distance_organic": Location(page: "Support", group: "Tree supports", order: 264),
        "0:tree_support_top_rate": Location(page: "Support", group: "Tree supports", order: 265),
        "0:tree_support_branch_diameter": Location(page: "Support", group: "Tree supports", order: 266),
        "0:tree_support_branch_diameter_organic": Location(page: "Support", group: "Tree supports", order: 267),
        "0:tree_support_branch_diameter_angle": Location(page: "Support", group: "Tree supports", order: 268),
        "0:tree_support_branch_angle": Location(page: "Support", group: "Tree supports", order: 269),
        "0:tree_support_branch_angle_organic": Location(page: "Support", group: "Tree supports", order: 270),
        "0:tree_support_angle_slow": Location(page: "Support", group: "Tree supports", order: 271),
        "0:tree_support_auto_brim": Location(page: "Support", group: "Tree supports", order: 272),
        "0:tree_support_brim_width": Location(page: "Support", group: "Tree supports", order: 273),
        "0:enable_prime_tower": Location(page: "Multimaterial", group: "Prime tower", order: 274),
        "0:prime_tower_skip_points": Location(page: "Multimaterial", group: "Prime tower", order: 275),
        "0:enable_tower_interface_features": Location(page: "Multimaterial", group: "Prime tower", order: 276),
        "0:enable_tower_interface_cooldown_during_tower": Location(page: "Multimaterial", group: "Prime tower", order: 277),
        "0:prime_tower_enable_framework": Location(page: "Multimaterial", group: "Prime tower", order: 278),
        "0:prime_tower_width": Location(page: "Multimaterial", group: "Prime tower", order: 279),
        "0:belt_purge_tower_width": Location(page: "Multimaterial", group: "Prime tower", order: 280),
        "0:prime_volume": Location(page: "Multimaterial", group: "Prime tower", order: 281),
        "0:prime_tower_brim_width": Location(page: "Multimaterial", group: "Prime tower", order: 282),
        "0:prime_tower_infill_gap": Location(page: "Multimaterial", group: "Prime tower", order: 283),
        "0:wipe_tower_rotation_angle": Location(page: "Multimaterial", group: "Prime tower", order: 284),
        "0:wipe_tower_bridging": Location(page: "Multimaterial", group: "Prime tower", order: 285),
        "0:wipe_tower_extra_spacing": Location(page: "Multimaterial", group: "Prime tower", order: 286),
        "0:wipe_tower_extra_flow": Location(page: "Multimaterial", group: "Prime tower", order: 287),
        "0:wipe_tower_max_purge_speed": Location(page: "Multimaterial", group: "Prime tower", order: 288),
        "0:wipe_tower_wall_type": Location(page: "Multimaterial", group: "Prime tower", order: 289),
        "0:wipe_tower_cone_angle": Location(page: "Multimaterial", group: "Prime tower", order: 290),
        "0:wipe_tower_extra_rib_length": Location(page: "Multimaterial", group: "Prime tower", order: 291),
        "0:wipe_tower_rib_width": Location(page: "Multimaterial", group: "Prime tower", order: 292),
        "0:wipe_tower_fillet_wall": Location(page: "Multimaterial", group: "Prime tower", order: 293),
        "0:wipe_tower_no_sparse_layers": Location(page: "Multimaterial", group: "Prime tower", order: 294),
        "0:wipe_tower_sparse_layers_combination": Location(page: "Multimaterial", group: "Prime tower", order: 295),
        "0:single_extruder_multi_material_priming": Location(page: "Multimaterial", group: "Prime tower", order: 296),
        "0:outer_wall_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 297),
        "0:inner_wall_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 298),
        "0:sparse_infill_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 299),
        "0:internal_solid_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 300),
        "0:top_surface_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 301),
        "0:bottom_surface_filament_id": Location(page: "Multimaterial", group: "Filament for Features", order: 302),
        "0:wipe_tower_filament": Location(page: "Multimaterial", group: "Filament for Features", order: 303),
        "0:ooze_prevention": Location(page: "Multimaterial", group: "Ooze prevention", order: 304),
        "0:standby_temperature_delta": Location(page: "Multimaterial", group: "Ooze prevention", order: 305),
        "0:preheat_time": Location(page: "Multimaterial", group: "Ooze prevention", order: 306),
        "0:preheat_steps": Location(page: "Multimaterial", group: "Ooze prevention", order: 307),
        "0:flush_into_infill": Location(page: "Multimaterial", group: "Flush options", order: 308),
        "0:flush_into_objects": Location(page: "Multimaterial", group: "Flush options", order: 309),
        "0:flush_into_support": Location(page: "Multimaterial", group: "Flush options", order: 310),
        "0:interlocking_beam": Location(page: "Multimaterial", group: "Advanced", order: 311),
        "0:toolchange_ordering": Location(page: "Multimaterial", group: "Advanced", order: 312),
        "0:toolchange_cyclic_order": Location(page: "Multimaterial", group: "Advanced", order: 313),
        "0:toolchange_cyclic_first_layer": Location(page: "Multimaterial", group: "Advanced", order: 314),
        "0:interface_shells": Location(page: "Multimaterial", group: "Advanced", order: 315),
        "0:mmu_segmented_region_max_width": Location(page: "Multimaterial", group: "Advanced", order: 316),
        "0:mmu_segmented_region_interlocking_depth": Location(page: "Multimaterial", group: "Advanced", order: 317),
        "0:interlocking_beam_width": Location(page: "Multimaterial", group: "Advanced", order: 318),
        "0:interlocking_orientation": Location(page: "Multimaterial", group: "Advanced", order: 319),
        "0:interlocking_beam_layer_count": Location(page: "Multimaterial", group: "Advanced", order: 320),
        "0:interlocking_depth": Location(page: "Multimaterial", group: "Advanced", order: 321),
        "0:interlocking_boundary_avoidance": Location(page: "Multimaterial", group: "Advanced", order: 322),
        "0:skirt_loops": Location(page: "Others", group: "Skirt", order: 323),
        "0:skirt_type": Location(page: "Others", group: "Skirt", order: 324),
        "0:min_skirt_length": Location(page: "Others", group: "Skirt", order: 325),
        "0:skirt_distance": Location(page: "Others", group: "Skirt", order: 326),
        "0:skirt_start_angle": Location(page: "Others", group: "Skirt", order: 327),
        "0:skirt_speed": Location(page: "Others", group: "Skirt", order: 328),
        "0:skirt_height": Location(page: "Others", group: "Skirt", order: 329),
        "0:draft_shield": Location(page: "Others", group: "Skirt", order: 330),
        "0:single_loop_draft_shield": Location(page: "Others", group: "Skirt", order: 331),
        "0:brim_type": Location(page: "Others", group: "Brim", order: 332),
        "0:brim_width": Location(page: "Others", group: "Brim", order: 333),
        "0:leading_brim_length": Location(page: "Others", group: "Brim", order: 334),
        "0:extra_brim_width": Location(page: "Others", group: "Brim", order: 335),
        "0:brim_object_gap": Location(page: "Others", group: "Brim", order: 336),
        "0:brim_flow_ratio": Location(page: "Others", group: "Brim", order: 337),
        "0:brim_use_efc_outline": Location(page: "Others", group: "Brim", order: 338),
        "0:combine_brims": Location(page: "Others", group: "Brim", order: 339),
        "0:brim_ears_max_angle": Location(page: "Others", group: "Brim", order: 340),
        "0:brim_ears_detection_length": Location(page: "Others", group: "Brim", order: 341),
        "0:brim_ears_outer_only": Location(page: "Others", group: "Brim", order: 342),
        "0:slicing_mode": Location(page: "Others", group: "Special mode", order: 343),
        "0:print_sequence": Location(page: "Others", group: "Special mode", order: 344),
        "0:print_order": Location(page: "Others", group: "Special mode", order: 345),
        "0:spiral_mode": Location(page: "Others", group: "Special mode", order: 346),
        "0:spiral_mode_smooth": Location(page: "Others", group: "Special mode", order: 347),
        "0:spiral_mode_max_xy_smoothing": Location(page: "Others", group: "Special mode", order: 348),
        "0:spiral_starting_flow_ratio": Location(page: "Others", group: "Special mode", order: 349),
        "0:spiral_finishing_flow_ratio": Location(page: "Others", group: "Special mode", order: 350),
        "0:timelapse_type": Location(page: "Others", group: "Special mode", order: 351),
        "0:enable_wrapping_detection": Location(page: "Others", group: "Special mode", order: 352),
        "0:fuzzy_skin": Location(page: "Others", group: "Fuzzy skin", order: 353),
        "0:fuzzy_skin_mode": Location(page: "Others", group: "Fuzzy skin", order: 354),
        "0:fuzzy_skin_noise_type": Location(page: "Others", group: "Fuzzy skin", order: 355),
        "0:fuzzy_skin_point_distance": Location(page: "Others", group: "Fuzzy skin", order: 356),
        "0:fuzzy_skin_thickness": Location(page: "Others", group: "Fuzzy skin", order: 357),
        "0:fuzzy_skin_scale": Location(page: "Others", group: "Fuzzy skin", order: 358),
        "0:fuzzy_skin_octaves": Location(page: "Others", group: "Fuzzy skin", order: 359),
        "0:fuzzy_skin_persistence": Location(page: "Others", group: "Fuzzy skin", order: 360),
        "0:fuzzy_skin_ripples_per_layer": Location(page: "Others", group: "Fuzzy skin", order: 361),
        "0:fuzzy_skin_ripple_offset": Location(page: "Others", group: "Fuzzy skin", order: 362),
        "0:fuzzy_skin_layers_between_ripple_offset": Location(page: "Others", group: "Fuzzy skin", order: 363),
        "0:fuzzy_skin_first_layer": Location(page: "Others", group: "Fuzzy skin", order: 364),
        "0:reduce_infill_retraction": Location(page: "Others", group: "G-code output", order: 365),
        "0:gcode_add_line_number": Location(page: "Others", group: "G-code output", order: 366),
        "0:gcode_comments": Location(page: "Others", group: "G-code output", order: 367),
        "0:high_precision_gcode": Location(page: "Others", group: "G-code output", order: 368),
        "0:gcode_label_objects": Location(page: "Others", group: "G-code output", order: 369),
        "0:exclude_object": Location(page: "Others", group: "G-code output", order: 370),
        "0:exclude_object_tolerance": Location(page: "Others", group: "G-code output", order: 371),
        "0:filename_format": Location(page: "Others", group: "G-code output", order: 372),
        "0:process_change_extrusion_role_gcode": Location(page: "Others", group: "Change extrusion role G-code", order: 373),
        "0:post_process": Location(page: "Others", group: "Post-processing Scripts", order: 374),
        "0:others_settings_post_processing_scripts": Location(page: "Others", group: "Post-processing Scripts", order: 375),
        "0:slicing_pipeline_plugin": Location(page: "Others", group: "Slicing Pipeline Plugin", order: 376),
        "0:print_plugin_config_overrides": Location(page: "Others", group: "Plugin Configuration", order: 377),
        "0:notes": Location(page: "Others", group: "Notes", order: 378),
        "0:others_settings_notes": Location(page: "Others", group: "Notes", order: 379),
        "1:filament_type": Location(page: "Filament", group: "Basic information", order: 380),
        "1:filament_vendor": Location(page: "Filament", group: "Basic information", order: 381),
        "1:filament_soluble": Location(page: "Filament", group: "Basic information", order: 382),
        "1:filament_is_support": Location(page: "Filament", group: "Basic information", order: 383),
        "1:filament_change_length": Location(page: "Filament", group: "Basic information", order: 384),
        "1:default_filament_colour": Location(page: "Filament", group: "Basic information", order: 385),
        "1:filament_diameter": Location(page: "Filament", group: "Basic information", order: 386),
        "1:filament_adhesiveness_category": Location(page: "Filament", group: "Basic information", order: 387),
        "1:filament_density": Location(page: "Filament", group: "Basic information", order: 388),
        "1:filament_shrink": Location(page: "Filament", group: "Basic information", order: 389),
        "1:filament_shrinkage_compensation_z": Location(page: "Filament", group: "Basic information", order: 390),
        "1:filament_cost": Location(page: "Filament", group: "Basic information", order: 391),
        "1:temperature_vitrification": Location(page: "Filament", group: "Basic information", order: 392),
        "1:idle_temperature": Location(page: "Filament", group: "Basic information", order: 393),
        "1:nozzle_temperature_range_low": Location(page: "Filament", group: "Basic information", order: 394),
        "1:nozzle_temperature_range_high": Location(page: "Filament", group: "Basic information", order: 395),
        "1:pellet_flow_coefficient": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 396),
        "1:filament_flow_ratio": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 397),
        "1:enable_pressure_advance": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 398),
        "1:pressure_advance": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 399),
        "1:adaptive_pressure_advance": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 400),
        "1:adaptive_pressure_advance_overhangs": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 401),
        "1:adaptive_pressure_advance_bridges": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 402),
        "1:adaptive_pressure_advance_model": Location(page: "Filament", group: "Flow ratio and Pressure Advance", order: 403),
        "1:activate_chamber_temp_control": Location(page: "Filament", group: "Print chamber temperature", order: 404),
        "1:chamber_temperature": Location(page: "Filament", group: "Print chamber temperature", order: 405),
        "1:chamber_minimal_temperature": Location(page: "Filament", group: "Print chamber temperature", order: 406),
        "1:nozzle_temperature_initial_layer": Location(page: "Filament", group: "Print temperature", order: 407),
        "1:nozzle_temperature": Location(page: "Filament", group: "Print temperature", order: 408),
        "1:supertack_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 409),
        "1:supertack_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 410),
        "1:cool_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 411),
        "1:cool_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 412),
        "1:textured_cool_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 413),
        "1:textured_cool_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 414),
        "1:eng_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 415),
        "1:eng_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 416),
        "1:hot_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 417),
        "1:hot_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 418),
        "1:textured_plate_temp_initial_layer": Location(page: "Filament", group: "Bed temperature", order: 419),
        "1:textured_plate_temp": Location(page: "Filament", group: "Bed temperature", order: 420),
        "1:filament_adaptive_volumetric_speed": Location(page: "Filament", group: "Volumetric speed limitation", order: 421),
        "1:filament_max_volumetric_speed": Location(page: "Filament", group: "Volumetric speed limitation", order: 422),
        "1:close_fan_the_first_x_layers": Location(page: "Cooling", group: "Cooling for specific layer", order: 423),
        "1:initial_layer_fan_speed": Location(page: "Cooling", group: "Cooling for specific layer", order: 424),
        "1:full_fan_speed_layer": Location(page: "Cooling", group: "Cooling for specific layer", order: 425),
        "1:fan_min_speed": Location(page: "Cooling", group: "Part cooling fan", order: 426),
        "1:fan_cooling_layer_time": Location(page: "Cooling", group: "Part cooling fan", order: 427),
        "1:fan_max_speed": Location(page: "Cooling", group: "Part cooling fan", order: 428),
        "1:slow_down_layer_time": Location(page: "Cooling", group: "Part cooling fan", order: 429),
        "1:reduce_fan_stop_start_freq": Location(page: "Cooling", group: "Part cooling fan", order: 430),
        "1:slow_down_for_layer_cooling": Location(page: "Cooling", group: "Part cooling fan", order: 431),
        "1:dont_slow_down_outer_wall": Location(page: "Cooling", group: "Part cooling fan", order: 432),
        "1:slow_down_min_speed": Location(page: "Cooling", group: "Part cooling fan", order: 433),
        "1:enable_overhang_bridge_fan": Location(page: "Cooling", group: "Part cooling fan", order: 434),
        "1:overhang_fan_threshold": Location(page: "Cooling", group: "Part cooling fan", order: 435),
        "1:overhang_fan_speed": Location(page: "Cooling", group: "Part cooling fan", order: 436),
        "1:internal_bridge_fan_speed": Location(page: "Cooling", group: "Part cooling fan", order: 437),
        "1:support_material_interface_fan_speed": Location(page: "Cooling", group: "Part cooling fan", order: 438),
        "1:ironing_fan_speed": Location(page: "Cooling", group: "Part cooling fan", order: 439),
        "1:additional_cooling_fan_speed": Location(page: "Cooling", group: "Auxiliary part cooling fan", order: 440),
        "1:activate_air_filtration": Location(page: "Cooling", group: "Exhaust fan", order: 441),
        "1:activate_air_filtration_during_print": Location(page: "Cooling", group: "Exhaust fan", order: 442),
        "1:during_print_exhaust_fan_speed": Location(page: "Cooling", group: "Exhaust fan", order: 443),
        "1:activate_air_filtration_on_completion": Location(page: "Cooling", group: "Exhaust fan", order: 444),
        "1:complete_print_exhaust_fan_speed": Location(page: "Cooling", group: "Exhaust fan", order: 445),
        "1:filament_start_gcode": Location(page: "Advanced", group: "Filament start G-code", order: 446),
        "1:filament_change_extrusion_role_gcode": Location(page: "Advanced", group: "Change extrusion role G-code", order: 447),
        "1:filament_end_gcode": Location(page: "Advanced", group: "Filament end G-code", order: 448),
        "1:filament_plugin_config_overrides": Location(page: "Advanced", group: "Plugin Configuration", order: 449),
        "1:filament_minimal_purge_on_wipe_tower": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 450),
        "1:filament_tower_interface_pre_extrusion_dist": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 451),
        "1:filament_tower_interface_pre_extrusion_length": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 452),
        "1:filament_tower_ironing_area": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 453),
        "1:filament_tower_interface_purge_volume": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 454),
        "1:filament_tower_interface_print_temp": Location(page: "Multimaterial", group: "Wipe tower parameters", order: 455),
        "1:long_retractions_when_ec": Location(page: "Multimaterial", group: "Multi Filament", order: 456),
        "1:retraction_distances_when_ec": Location(page: "Multimaterial", group: "Multi Filament", order: 457),
        "1:filament_loading_speed_start": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 458),
        "1:filament_loading_speed": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 459),
        "1:filament_unloading_speed_start": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 460),
        "1:filament_unloading_speed": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 461),
        "1:filament_toolchange_delay": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 462),
        "1:filament_cooling_moves": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 463),
        "1:filament_cooling_initial_speed": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 464),
        "1:filament_cooling_final_speed": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 465),
        "1:filament_stamping_loading_speed": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 466),
        "1:filament_stamping_distance": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 467),
        "1:filament_ramming_parameters": Location(page: "Multimaterial", group: "Tool change parameters with single extruder MM printers", order: 468),
        "1:filament_multitool_ramming": Location(page: "Multimaterial", group: "Tool change parameters with multi extruder MM printers", order: 469),
        "1:filament_multitool_ramming_volume": Location(page: "Multimaterial", group: "Tool change parameters with multi extruder MM printers", order: 470),
        "1:filament_multitool_ramming_flow": Location(page: "Multimaterial", group: "Tool change parameters with multi extruder MM printers", order: 471),
        "1:compatible_printers": Location(page: "Dependencies", group: "Compatible printers", order: 472),
        "1:compatible_printers_condition": Location(page: "Dependencies", group: "Compatible printers", order: 473),
        "1:compatible_prints": Location(page: "Dependencies", group: "Compatible process profiles", order: 474),
        "1:compatible_prints_condition": Location(page: "Dependencies", group: "Compatible process profiles", order: 475),
        "1:filament_notes": Location(page: "Notes", group: "Notes", order: 476),
        "2:printable_area": Location(page: "Basic information", group: "Printable space", order: 477),
        "2:parallel_printheads_count": Location(page: "Basic information", group: "Printable space", order: 478),
        "2:bed_exclude_area": Location(page: "Basic information", group: "Printable space", order: 479),
        "2:bed_exclude_volumes": Location(page: "Basic information", group: "Printable space", order: 480),
        "2:bed_exclude_volume_mode": Location(page: "Basic information", group: "Printable space", order: 481),
        "2:printable_height": Location(page: "Basic information", group: "Printable space", order: 482),
        "2:support_multi_bed_types": Location(page: "Basic information", group: "Printable space", order: 483),
        "2:best_object_pos": Location(page: "Basic information", group: "Printable space", order: 484),
        "2:z_offset": Location(page: "Basic information", group: "Printable space", order: 485),
        "2:preferred_orientation": Location(page: "Basic information", group: "Printable space", order: 486),
        "2:printer_structure": Location(page: "Basic information", group: "Advanced", order: 487),
        "2:gcode_flavor": Location(page: "Basic information", group: "Advanced", order: 488),
        "2:gcode_skip_config_block": Location(page: "Basic information", group: "Advanced", order: 489),
        "2:pellet_modded_printer": Location(page: "Basic information", group: "Advanced", order: 490),
        "2:bbl_use_printhost": Location(page: "Basic information", group: "Advanced", order: 491),
        "2:printer_agent": Location(page: "Basic information", group: "Advanced", order: 492),
        "2:use_3mf": Location(page: "Basic information", group: "Advanced", order: 493),
        "2:scan_first_layer": Location(page: "Basic information", group: "Advanced", order: 494),
        "2:enable_power_loss_recovery": Location(page: "Basic information", group: "Advanced", order: 495),
        "2:disable_m73": Location(page: "Basic information", group: "Advanced", order: 496),
        "2:belt_printer": Location(page: "Basic information", group: "Belt printer", order: 497),
        "2:belt_printer_infinite_y": Location(page: "Basic information", group: "Belt printer", order: 498),
        "2:belt_slice_rotation_angle": Location(page: "Basic information", group: "Belt printer", order: 499),
        "2:belt_slice_rotation": Location(page: "Basic information", group: "Belt printer", order: 500),
        "2:belt_support_floor_offset": Location(page: "Basic information", group: "Belt printer", order: 501),
        "2:gcode_remap_x": Location(page: "Basic information", group: "Machine frame transforms", order: 502),
        "2:gcode_remap_y": Location(page: "Basic information", group: "Machine frame transforms", order: 503),
        "2:gcode_remap_z": Location(page: "Basic information", group: "Machine frame transforms", order: 504),
        "2:belt_frame_tilt_decouple": Location(page: "Basic information", group: "Machine frame transforms", order: 505),
        "2:belt_frame_tilt_angle": Location(page: "Basic information", group: "Machine frame transforms", order: 506),
        "2:thumbnails": Location(page: "Basic information", group: "Machine frame transforms", order: 507),
        "2:use_relative_e_distances": Location(page: "Basic information", group: "Machine frame transforms", order: 508),
        "2:use_firmware_retraction": Location(page: "Basic information", group: "Machine frame transforms", order: 509),
        "2:time_cost": Location(page: "Basic information", group: "Machine frame transforms", order: 510),
        "2:build_plate_tilt_x": Location(page: "Basic information", group: "Machine frame transforms", order: 511),
        "2:build_plate_tilt_y": Location(page: "Basic information", group: "Machine frame transforms", order: 512),
        "2:printer_plugin_config_overrides": Location(page: "Basic information", group: "Plugin Configuration", order: 513),
        "2:fan_speedup_time": Location(page: "Basic information", group: "Cooling Fan", order: 514),
        "2:fan_speedup_overhangs": Location(page: "Basic information", group: "Cooling Fan", order: 515),
        "2:fan_kickstart": Location(page: "Basic information", group: "Cooling Fan", order: 516),
        "2:part_cooling_fan_min_pwm": Location(page: "Basic information", group: "Cooling Fan", order: 517),
        "2:extruder_clearance_radius": Location(page: "Basic information", group: "Extruder Clearance", order: 518),
        "2:extruder_clearance_dist_to_rod": Location(page: "Basic information", group: "Extruder Clearance", order: 519),
        "2:extruder_clearance_height_to_rod": Location(page: "Basic information", group: "Extruder Clearance", order: 520),
        "2:extruder_clearance_height_to_lid": Location(page: "Basic information", group: "Extruder Clearance", order: 521),
        "2:bed_mesh_min": Location(page: "Basic information", group: "Adaptive bed mesh", order: 522),
        "2:bed_mesh_max": Location(page: "Basic information", group: "Adaptive bed mesh", order: 523),
        "2:bed_mesh_probe_distance": Location(page: "Basic information", group: "Adaptive bed mesh", order: 524),
        "2:adaptive_bed_mesh_margin": Location(page: "Basic information", group: "Adaptive bed mesh", order: 525),
        "2:nozzle_hrc": Location(page: "Basic information", group: "Accessory", order: 526),
        "2:auxiliary_fan": Location(page: "Basic information", group: "Accessory", order: 527),
        "2:fan_direction": Location(page: "Basic information", group: "Accessory", order: 528),
        "2:support_chamber_temp_control": Location(page: "Basic information", group: "Accessory", order: 529),
        "2:support_air_filtration": Location(page: "Basic information", group: "Accessory", order: 530),
        "2:cooling_filter_enabled": Location(page: "Basic information", group: "Accessory", order: 531),
        "2:file_start_gcode": Location(page: "Machine G-code", group: "File header G-code", order: 532),
        "2:machine_start_gcode": Location(page: "Machine G-code", group: "Machine start G-code", order: 533),
        "2:machine_end_gcode": Location(page: "Machine G-code", group: "Machine end G-code", order: 534),
        "2:printing_by_object_gcode": Location(page: "Machine G-code", group: "Printing by object G-code", order: 535),
        "2:before_layer_change_gcode": Location(page: "Machine G-code", group: "Before layer change G-code", order: 536),
        "2:layer_change_gcode": Location(page: "Machine G-code", group: "Layer change G-code", order: 537),
        "2:time_lapse_gcode": Location(page: "Machine G-code", group: "Timelapse G-code", order: 538),
        "2:wrapping_detection_gcode": Location(page: "Machine G-code", group: "Clumping Detection G-code", order: 539),
        "2:change_filament_gcode": Location(page: "Machine G-code", group: "Change filament G-code", order: 540),
        "2:change_extrusion_role_gcode": Location(page: "Machine G-code", group: "Change extrusion role G-code", order: 541),
        "2:machine_pause_gcode": Location(page: "Machine G-code", group: "Pause G-code", order: 542),
        "2:template_custom_gcode": Location(page: "Machine G-code", group: "Template Custom G-code", order: 543),
        "2:printer_notes": Location(page: "Notes", group: "Notes", order: 544),
        "2:emit_machine_limits_to_gcode": Location(page: "Motion ability", group: "Advanced", order: 545),
        "2:resonance_avoidance": Location(page: "Motion ability", group: "Resonance Compensation", order: 546),
        "2:min_resonance_avoidance_speed": Location(page: "Motion ability", group: "Resonance Compensation", order: 547),
        "2:max_resonance_avoidance_speed": Location(page: "Motion ability", group: "Resonance Compensation", order: 548),
        "2:input_shaping_emit": Location(page: "Motion ability", group: "Resonance Compensation", order: 549),
        "2:input_shaping_type": Location(page: "Motion ability", group: "Resonance Compensation", order: 550),
        "2:input_shaping_freq_x": Location(page: "Motion ability", group: "Resonance Compensation", order: 551),
        "2:input_shaping_freq_y": Location(page: "Motion ability", group: "Resonance Compensation", order: 552),
        "2:input_shaping_damp_x": Location(page: "Motion ability", group: "Resonance Compensation", order: 553),
        "2:input_shaping_damp_y": Location(page: "Motion ability", group: "Resonance Compensation", order: 554),
        "2:machine_max_acceleration_": Location(page: "Motion ability", group: "Acceleration limitation", order: 555),
        "2:machine_max_acceleration_extruding": Location(page: "Motion ability", group: "Acceleration limitation", order: 556),
        "2:machine_max_acceleration_retracting": Location(page: "Motion ability", group: "Acceleration limitation", order: 557),
        "2:machine_max_acceleration_travel": Location(page: "Motion ability", group: "Acceleration limitation", order: 558),
        "2:machine_max_junction_deviation": Location(page: "Motion ability", group: "Jerk limitation", order: 559),
        "2:machine_max_jerk_": Location(page: "Motion ability", group: "Jerk limitation", order: 560),
        "2:single_extruder_multi_material": Location(page: "Multimaterial", group: "Single extruder multi-material setup", order: 561),
        "2:manual_filament_change": Location(page: "Multimaterial", group: "Single extruder multi-material setup", order: 562),
        "2:bed_temperature_formula": Location(page: "Multimaterial", group: "Single extruder multi-material setup", order: 563),
        "2:wipe_tower_type": Location(page: "Multimaterial", group: "Wipe tower", order: 564),
        "2:purge_in_prime_tower": Location(page: "Multimaterial", group: "Wipe tower", order: 565),
        "2:enable_filament_ramming": Location(page: "Multimaterial", group: "Wipe tower", order: 566),
        "2:tool_change_on_wipe_tower": Location(page: "Multimaterial", group: "Wipe tower", order: 567),
        "2:wait_for_temp_on_wipe_tower": Location(page: "Multimaterial", group: "Wipe tower", order: 568),
        "2:enable_belt_purge_tower": Location(page: "Multimaterial", group: "Belt purge tower", order: 569),
        "2:cooling_tube_retraction": Location(page: "Multimaterial", group: "Single extruder multi-material parameters", order: 570),
        "2:cooling_tube_length": Location(page: "Multimaterial", group: "Single extruder multi-material parameters", order: 571),
        "2:parking_pos_retraction": Location(page: "Multimaterial", group: "Single extruder multi-material parameters", order: 572),
        "2:extra_loading_move": Location(page: "Multimaterial", group: "Single extruder multi-material parameters", order: 573),
        "2:high_current_on_filament_swap": Location(page: "Multimaterial", group: "Single extruder multi-material parameters", order: 574),
        "2:machine_load_filament_time": Location(page: "Multimaterial", group: "Advanced", order: 575),
        "2:machine_unload_filament_time": Location(page: "Multimaterial", group: "Advanced", order: 576),
        "2:machine_tool_change_time": Location(page: "Multimaterial", group: "Advanced", order: 577),
        "2:is_imex": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 578),
        "2:imex_firmware_managed_zones": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 579),
        "2:imex_gantry_count": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 580),
        "2:imex_tools_per_gantry": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 581),
        "2:imex_tool_layout": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 582),
        "2:imex_nozzle_clearance_x": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 583),
        "2:imex_nozzle_clearance_y": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 584),
        "2:imex_carriage_margin": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 585),
        "2:imex_viz_theme": Location(page: "Multimaterial", group: "IDEX/IQEX Configuration", order: 586),
        "2:nozzle_diameter": Location(page: "Extruder", group: "Basic information", order: 587),
        "2:nozzle_type": Location(page: "Extruder", group: "Basic information", order: 588),
        "2:nozzle_volume": Location(page: "Extruder", group: "Basic information", order: 589),
        "2:extruder_printable_height": Location(page: "Extruder", group: "Basic information", order: 590),
        "2:extruder_printable_area": Location(page: "Extruder", group: "Basic information", order: 591),
        "2:extruder_bed_exclude_volumes": Location(page: "Extruder", group: "Basic information", order: 592),
        "2:min_layer_height": Location(page: "Extruder", group: "Layer height limits", order: 593),
        "2:max_layer_height": Location(page: "Extruder", group: "Layer height limits", order: 594),
        "2:extruder_offset": Location(page: "Extruder", group: "Position", order: 595),
        "2:retract_length_toolchange": Location(page: "Extruder", group: "Retraction when switching material", order: 596),
        "2:retract_restart_extra_toolchange": Location(page: "Extruder", group: "Retraction when switching material", order: 597),
        "2:long_retractions_when_cut": Location(page: "Extruder", group: "Retraction when switching material", order: 598),
        "2:retraction_distances_when_cut": Location(page: "Extruder", group: "Retraction when switching material", order: 599),
    ]
}

/// Native hook configuration writes the same post_process field desktop Orca uses.
struct NativeProcessingPanel: View {
    @ObservedObject var engine: OrcaEngine
    @State private var commands = ""
    @State private var message = ""
    var body: some View {
        Form {
            Section("G-code post-processing") {
                Text("Hooks run after slicing, before sharing or sending G-code.")
                TextField("Serialized desktop script list", text: $commands, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Apply") {
                    if engine.applyConfigOption(key: "post_process", value: commands) { message = "Saved to the current process preset." }
                    else { message = engine.lastMessage }
                }
                Button("Use Zmod preprocessing") {
                    commands = "zmod-preprocess.py"
                    if engine.applyConfigOption(key: "post_process", value: commands) { message = "Zmod enabled. Save the process preset to keep this setting." }
                    else { message = engine.lastMessage }
                }
                Button("Disable post-processing") {
                    commands = ""
                    _ = engine.applyConfigOption(key: "post_process", value: commands)
                    message = engine.lastMessage
                }
            }
            Section("Zmod · native implementation") {
                Text("Adds MD5 and filament metadata. Object outlines use the upstream 0.2 mm simplification default. Existing Python and compiled Zmod command paths resolve to this implementation.")
                Text("Supported arguments: --no-simplify-objects, --simplify-objects <mm>.")
                Link("Zmod source and documentation", destination: URL(string: "https://github.com/ghzserg/zmod_preprocess")!)
            }
            Section("Desktop plugin compatibility") {
                Text("Arbitrary Python plugins and desktop dynamic libraries do not have a runtime in this iOS build. Unsupported script commands stop export with an error.")
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }.navigationTitle("Post-processing plugins")
            .onAppear { commands = engine.getOption("post_process") ?? "" }
    }
}
