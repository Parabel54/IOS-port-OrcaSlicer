import SwiftUI

struct CloudAccountPanel: View {
    @ObservedObject var account: OrcaCloudAccount
    @ObservedObject var connections: PrinterConnections
    @State private var email = ""
    @State private var password = ""
    @State private var phone = ""
    @State private var verificationCode = ""
    @State private var organizationDomain = ""

    var body: some View {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            Text("Orca Cloud").font(.headline)
            if account.signedIn {
                Text(account.displayName).font(.subheadline)
                HStack {
                    Button("Sync printers") { Task { await account.sync() } }
                        .disabled(account.busy)
                    Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                }
                if let date = account.lastSynced {
                    Text("Last synchronized: \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if account.printers.isEmpty, account.lastSynced != nil {
                    Text("No printers are linked to this Orca Cloud account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(account.printers) { printer in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(printer.name).font(.subheadline.bold())
                        Text(printer.online ? "Online" : "Offline").font(.caption)
                        if let model = printer.model { Text(model).font(.caption) }
                        if let state = printer.jobState { Text(state).font(.caption) }
                        if let role = printer.access_role { Text("Access: \(role)").font(.caption).foregroundStyle(.secondary) }
                        if let local = connections.printers.first(where: { $0.cloudPrinterID == printer.id }) {
                            Text("Local connection: \(local.name)").font(.caption)
                            Button("Unlink local connection") { connections.link(local, toCloudPrinter: nil) }
                        } else if !connections.printers.isEmpty {
                            Menu("Link a saved local connection") {
                                ForEach(connections.printers) { local in
                                    Button(local.name) { connections.link(local, toCloudPrinter: printer.id) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Text("Cloud sync updates printer names and status. Local printer addresses and access codes stay on this device. New cloud printer registration is managed in Orca Cloud.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if account.needsMFACode || account.pendingPhone != nil {
                verificationForm
            } else {
                loginMethods
            }
            if account.busy { ProgressView(account.signingIn ? "Signing in…" : "Synchronizing…") }
            if account.signingIn || account.needsMFACode || account.pendingPhone != nil { Button("Cancel sign-in") { account.cancelSignIn() } }
            if !account.message.isEmpty { Text(account.message).font(.caption) }
        })
        .task(id: account.signedIn) {
            await account.loadLoginMethods()
            guard account.signedIn else { return }
            while !Task.isCancelled {
                await account.sync()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
            }
        }
    }

    private var loginMethods: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            ForEach(account.providers) { provider in
                Button("Sign in with \(provider.name)") {
                    Task { await account.signIn(provider: provider.id) }
                }
            }
            if account.emailEnabled {
                Divider()
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
                Button("Sign in with email") {
                    let credential = password
                    password = ""
                    Task { await account.signIn(email: email, password: credential) }
                }
            }
            if account.phoneEnabled {
                Divider()
                TextField("Phone number with country code", text: $phone)
                    .textContentType(.telephoneNumber).keyboardType(.phonePad)
                Button("Send SMS sign-in code") { Task { await account.requestSMS(phone: phone) } }
            }
            if account.ssoEnabled {
                Divider()
                TextField("Organization domain", text: $organizationDomain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Sign in with organization SSO") { Task { await account.signInSSO(domain: organizationDomain) } }
            }
        }.disabled(account.busy))
    }

    private var verificationForm: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            Text(account.needsMFACode ? account.mfaDescription : String(localized: "Enter the code sent to your phone."))
            TextField("Verification code", text: $verificationCode)
                .textContentType(.oneTimeCode).keyboardType(.numberPad)
            Button("Verify and sign in") {
                let code = verificationCode
                verificationCode = ""
                Task { await account.verifyCode(code) }
            }
        }.disabled(account.busy))
    }
}
