import SwiftUI
import SafariServices

// Safari handles the hosted account flow and its cookies; no passwords or web tokens
// are copied into the slicer. A portal session is distinct from native preset sync.
struct ConnectionBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct PrinterConnectionsPanel: View {
    @ObservedObject var account: OrcaCloudAccount
    @ObservedObject var engine: OrcaEngine
    @ObservedObject var connections: PrinterConnections
    let address: String
    let kind: String
    let apiKey: String
    let serialNumber: String?
    let onSelect: (PrinterConnection) -> Void
    @State private var name = ""
    @State private var remotePrinter: PrinterConnection?
    @State private var browser: BrowserDestination?

    private struct BrowserDestination: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudAccountPanel(account: account, engine: engine, connections: connections)
            Button("Open cloud website") {
                browser = BrowserDestination(url: URL(string: "https://cloud.orcaslicer.com")!)
            }
            Divider()
            Text("Saved printers").font(.headline)
            ForEach(connections.printers) { printer in
                HStack {
                    Button { onSelect(printer) } label: {
                        VStack(alignment: .leading) {
                            Text(printer.name)
                            Text("\(printer.kind) · \(printer.connectionAddress)").font(.caption)
                        }
                    }
                    Spacer()
                    Button { remotePrinter = printer } label: { Image(systemName: "network") }
                        .accessibilityLabel(Text("Remote access for \(printer.name)"))
                    Button(role: .destructive) { connections.remove(printer) } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("Remove saved printer"))
                }
            }
            TextField("Printer name", text: $name)
                .textFieldStyle(.roundedBorder)
            Button("Save current connection") {
                connections.save(name: name, address: address, kind: kind, apiKey: apiKey, serialNumber: serialNumber)
            }
            if !connections.message.isEmpty {
                Text(connections.message).font(.caption)
            }
            Divider()
            NavigationLink("Post-processing plugins") { NativeProcessingPanel(engine: engine) }
            Button("Open printer web interface") {
                if let url = PrinterConnection.validatedURL(address) {
                    browser = BrowserDestination(url: url)
                }
            }
            .disabled(PrinterConnection.validatedURL(address) == nil)
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $browser) { ConnectionBrowser(url: $0.url) }
        .sheet(item: $remotePrinter) { printer in
            RemotePrinterRoutePanel(printer: printer, connections: connections)
        }
    }
}

struct RemotePrinterRoutePanel: View {
    let printer: PrinterConnection
    @ObservedObject var connections: PrinterConnections
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var enabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection route") {
                    Text(printer.name)
                    Text("Local: \(printer.address)").font(.caption)
                    TextField("Remote or VPN printer URL", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Use remote route", isOn: $enabled)
                }
                Section("Access from other networks") {
                    if printer.kind == "Flashforge TCP" {
                        Text("Enable Tailscale or WireGuard on this device and your home network. Enter the printer’s reachable VPN address, such as tcp://printer.home:8899. An HTTP relay cannot carry this TCP connection.")
                    } else {
                        Text("Use a VPN such as Tailscale or WireGuard on this device and your home network, or enter a reachable HTTPS relay URL. The printer must be reachable through that route.")
                    }
                    Text("Orca Cloud preset sync does not provide a tunnel to LAN printers. Your saved printer credentials are also used for the remote route.")
                }
                if !connections.message.isEmpty { Text(connections.message) }
                Button("Save route") {
                    connections.setRemoteRoute(for: printer, address: address, enabled: enabled)
                    if connections.printers.first(where: { $0.id == printer.id })?.useRemote == enabled,
                       connections.printers.first(where: { $0.id == printer.id })?.remoteAddress == (address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                }
            }.navigationTitle("Remote access")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .onAppear { address = printer.remoteAddress ?? ""; enabled = printer.useRemote == true; connections.message = "" }
        }
    }
}
