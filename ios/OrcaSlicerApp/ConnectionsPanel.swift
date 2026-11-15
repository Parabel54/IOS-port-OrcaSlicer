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
    @ObservedObject var connections: PrinterConnections
    let address: String
    let kind: String
    let apiKey: String
    let serialNumber: String?
    let onSelect: (PrinterConnection) -> Void
    @State private var name = ""
    @State private var browser: BrowserDestination?

    private struct BrowserDestination: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CloudAccountPanel(account: account, connections: connections)
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
                            Text("\(printer.kind) · \(printer.address)").font(.caption)
                        }
                    }
                    Spacer()
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
            Text("Plugins").font(.headline)
            Text("Flashforge AD5X/5M, Moonraker, OctoPrint, and PrusaLink connections are built in. Open your printer’s web interface to use its installed web plugins. Desktop networking plugins require an iOS-compatible build and are not loaded by this app.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    }
}
