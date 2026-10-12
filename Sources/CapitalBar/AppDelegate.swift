import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CapitalClient()
    private let menu = NSMenu()
    private var timer: Timer?

    private var env: TradingEnv = .demo
    private var account: Account?
    private var positions: [Position] = []
    private var favourites: [String] = []
    private var quotes: [MarketQuote] = []
    private var lastError: String?
    private var lastUpdate: Date?
    private var busy = false

    private let refreshSeconds: TimeInterval = 10

    // Epics resolved from Capital's market search: Gold, Brent, SpaceX,
    // Alphabet class A, Tesla.
    private static let defaultFavourites = ["GOLD", "OIL_BRENT", "SPCX", "GOOGL", "TSLA"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.load()
        env = TradingEnv(rawValue: UserDefaults.standard.string(forKey: "env") ?? "") ?? Config.defaultEnv
        favourites = UserDefaults.standard.stringArray(forKey: "favourites") ?? Self.defaultFavourites

        menu.delegate = self
        menu.autoenablesItems = false // explicit isEnabled wins (closed markets, info rows)
        statusItem.menu = menu
        statusItem.button?.image = Logo.statusImage()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "…"

        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Data

    private func creds() -> Creds? { Config.creds(for: env) }

    private func refresh() {
        guard !busy, let creds = creds() else {
            if creds() == nil {
                lastError = "No credentials found (looked in \(Config.searchPaths.joined(separator: ", ")))"
                render()
            }
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                async let accountsTask = client.accounts(env: env, creds: creds)
                async let positionsTask = client.positions(env: env, creds: creds)
                async let quotesTask = client.quotes(epics: favourites, env: env, creds: creds)
                let (accounts, positions, quotes) = try await (accountsTask, positionsTask, quotesTask)
                self.account = accounts.first(where: { $0.preferred == true }) ?? accounts.first
                self.positions = positions
                self.quotes = quotes
                self.lastError = nil
                self.lastUpdate = Date()
            } catch {
                self.lastError = error.localizedDescription
            }
            render()
        }
    }

    private var openPnL: Double { positions.reduce(0) { $0 + $1.pnl } }

    private var currency: String {
        account?.currency ?? positions.first?.position.currency ?? ""
    }

    // MARK: - Rendering

    private func render() {
        renderTitle()
        rebuildMenu()
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        if lastError != nil && account == nil {
            button.attributedTitle = NSAttributedString(
                string: " ⚠", attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
            return
        }

        let pnl = openPnL
        let color: NSColor = positions.isEmpty ? .labelColor : (pnl >= 0 ? .systemGreen : .systemRed)
        let text = positions.isEmpty
            ? (account?.balance?.balance).map { "\(Fmt.money($0)) · flat" } ?? "—"
            : "\(Fmt.signed(pnl)) · \(positions.count)"

        let title = NSMutableAttributedString()
        if env == .live {
            // Real money gets a red dot; demo shows the plain mark only.
            title.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.systemRed,
                .baselineOffset: 1,
            ]))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        button.attributedTitle = title
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Capital.com · \(env.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let b = account?.balance {
            addInfo("Balance: \(Fmt.money(b.balance ?? 0)) \(currency)")
            addInfo("Available: \(Fmt.money(b.available ?? 0))   Equity: \(Fmt.money((b.balance ?? 0) + openPnL))")
            addInfo("Account P&L today: \(Fmt.signed(b.profitLoss ?? 0))")
        }
        addInfo("Open P&L: \(Fmt.signed(openPnL)) across \(positions.count) position\(positions.count == 1 ? "" : "s")")

        menu.addItem(.separator())

        if positions.isEmpty {
            addInfo("No open positions")
        } else {
            for p in positions.sorted(by: { $0.pnl < $1.pnl }) {
                let d = p.position
                let title = "\(d.direction.uppercased()) \(Fmt.size(d.size)) \(p.name) @ \(Fmt.level(d.level))   \(Fmt.signed(p.pnl))"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: p.pnl >= 0 ? NSColor.systemGreen : NSColor.systemRed,
                ])

                // Closing sits behind a submenu so a stray click on the row
                // can never fire an order.
                let sub = NSMenu()
                sub.autoenablesItems = false
                let close = NSMenuItem(title: "Close position", action: #selector(closeTapped(_:)), keyEquivalent: "")
                close.target = self
                close.representedObject = p
                sub.addItem(close)
                sub.addItem(.separator())
                let bid = p.market.bid.map(Fmt.level) ?? "—"
                let offer = p.market.offer.map(Fmt.level) ?? "—"
                sub.addItem(disabled("Market: \(bid) / \(offer) · \(p.market.marketStatus ?? "?")"))
                sub.addItem(disabled("Stop: \(d.stopLevel.map(Fmt.level) ?? "none")   Limit: \(d.profitLevel.map(Fmt.level) ?? "none")"))
                sub.addItem(disabled("Epic: \(p.market.epic)"))
                sub.addItem(disabled("Deal: \(d.dealId)"))
                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addFavouritesSection()
        menu.addItem(.separator())

        let trade = NSMenuItem(title: "New Trade…", action: #selector(newTradeTapped), keyEquivalent: "n")
        trade.target = self
        menu.addItem(trade)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshTapped), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let envMenu = NSMenu()
        envMenu.autoenablesItems = false
        for e in [TradingEnv.demo, .live] {
            let item = NSMenuItem(title: e == .live ? "Live (real money)" : "Demo", action: #selector(envTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.rawValue
            item.state = e == env ? .on : .off
            envMenu.addItem(item)
        }
        let envItem = NSMenuItem(title: "Environment: \(env.label)", action: nil, keyEquivalent: "")
        envItem.submenu = envMenu
        menu.addItem(envItem)

        menu.addItem(.separator())

        if let lastError {
            let item = disabled("⚠ \(lastError)")
            item.attributedTitle = NSAttributedString(string: "⚠ \(String(lastError.prefix(120)))",
                                                      attributes: [.foregroundColor: NSColor.systemOrange,
                                                                   .font: NSFont.systemFont(ofSize: 11)])
            menu.addItem(item)
        }
        if let lastUpdate {
            menu.addItem(disabled("Updated \(Fmt.time(lastUpdate)) · config: \(Config.sourcePath.map { ($0 as NSString).lastPathComponent } ?? "none")"))
        }

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addFavouritesSection() {
        menu.addItem(disabled("Watchlist"))

        // Keep the user's ordering — the batch endpoint returns whatever order
        // it likes.
        let byEpic = Dictionary(quotes.map { ($0.epic, $0) }, uniquingKeysWith: { a, _ in a })
        for epic in favourites {
            guard let q = byEpic[epic] else {
                menu.addItem(disabled("  \(epic) …"))
                continue
            }
            let price = q.mid.map(Fmt.level) ?? "—"
            let pct = q.snapshot.percentageChange
            let pctText = pct.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "−", abs($0)) } ?? ""
            let closed = q.isTradeable ? "" : "  ·  closed"
            let title = "  \(Fmt.pad(q.name, 22))\(Fmt.pad(price, 11))\(pctText)\(closed)"

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let colour: NSColor = !q.isTradeable ? .secondaryLabelColor
                : (pct ?? 0) >= 0 ? .systemGreen : .systemRed
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: colour,
            ])

            let sub = NSMenu()
            sub.autoenablesItems = false
            let trade = NSMenuItem(title: "Trade \(q.name)…", action: #selector(favouriteTradeTapped(_:)), keyEquivalent: "")
            trade.target = self
            trade.representedObject = q
            trade.isEnabled = q.isTradeable
            sub.addItem(trade)
            sub.addItem(.separator())
            sub.addItem(disabled("Bid \(q.snapshot.bid.map(Fmt.level) ?? "—")  /  Offer \(q.snapshot.offer.map(Fmt.level) ?? "—")"))
            sub.addItem(disabled("Day high \(q.snapshot.high.map(Fmt.level) ?? "—")  low \(q.snapshot.low.map(Fmt.level) ?? "—")"))
            sub.addItem(disabled("Status: \(q.snapshot.marketStatus ?? "?")  ·  \(q.epic)"))
            sub.addItem(.separator())
            let remove = NSMenuItem(title: "Remove from watchlist", action: #selector(removeFavouriteTapped(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = q.epic
            sub.addItem(remove)
            item.submenu = sub
            menu.addItem(item)
        }

        let add = NSMenuItem(title: "Add to Watchlist…", action: #selector(addFavouriteTapped), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
    }

    private func addInfo(_ text: String) { menu.addItem(disabled(text)) }

    private func disabled(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    // MARK: - Actions

    @objc private func refreshTapped() { refresh() }

    @objc private func envTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let next = TradingEnv(rawValue: raw), next != env else { return }
        if next == .live {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Switch to your LIVE account?"
            alert.informativeText = "Trades placed from this menu will use real money."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Switch to Live")
            alert.buttons.last?.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        env = next
        UserDefaults.standard.set(env.rawValue, forKey: "env")
        account = nil
        positions = []
        lastError = nil
        render()
        refresh()
    }

    @objc private func closeTapped(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Position, let creds = creds() else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Close \(p.position.direction.uppercased()) \(Fmt.size(p.position.size)) \(p.name)?"
        alert.informativeText = "\(env.label) account · current P&L \(Fmt.signed(p.pnl))\nThis sends a market order to close the position."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Position")
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        Task { @MainActor in
            do {
                let c = try await client.closePosition(dealId: p.position.dealId, env: env, creds: creds)
                report(confirmation: c, action: "Close")
            } catch {
                showError(error)
            }
            refresh()
        }
    }

    private func saveFavourites() {
        UserDefaults.standard.set(favourites, forKey: "favourites")
    }

    @objc private func removeFavouriteTapped(_ sender: NSMenuItem) {
        guard let epic = sender.representedObject as? String else { return }
        favourites.removeAll { $0 == epic }
        quotes.removeAll { $0.epic == epic }
        saveFavourites()
        render()
    }

    @objc private func addFavouriteTapped() {
        guard let creds = creds() else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let term = TradeDialogs.askSearchTerm(title: "Add to watchlist") else { return }
        Task { @MainActor in
            do {
                let results = try await client.search(term, env: env, creds: creds)
                guard !results.isEmpty else { return showMessage("No markets found", "Nothing matched “\(term)”.") }
                guard let picked = TradeDialogs.askMarket(results: results) else { return }
                guard !favourites.contains(picked.epic) else { return }
                favourites.append(picked.epic)
                saveFavourites()
                refresh()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func favouriteTradeTapped(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? MarketQuote else { return }
        let market = MarketSearchResult(epic: q.epic, instrumentName: q.name,
                                        bid: q.snapshot.bid, offer: q.snapshot.offer,
                                        marketStatus: q.snapshot.marketStatus)
        NSApp.activate(ignoringOtherApps: true)
        placeOrder(from: [market])
    }

    @objc private func newTradeTapped() {
        guard let creds = creds() else { return }
        NSApp.activate(ignoringOtherApps: true)

        guard let term = TradeDialogs.askSearchTerm(title: "New trade") else { return }
        Task { @MainActor in
            do {
                let results = try await client.search(term, env: env, creds: creds)
                guard !results.isEmpty else {
                    showMessage("No markets found", "Nothing matched “\(term)”.")
                    return
                }
                placeOrder(from: results)
            } catch {
                showError(error)
            }
        }
    }

    // Shared by "New Trade…" and the watchlist submenus: pick size/direction,
    // confirm, send, report.
    private func placeOrder(from markets: [MarketSearchResult]) {
        guard let creds = creds() else { return }
        guard let order = TradeDialogs.askOrder(results: markets, env: env) else { return }

        Task { @MainActor in
            do {
                let alert = NSAlert()
                alert.messageText = "\(order.direction) \(Fmt.size(order.size)) \(order.name)?"
                var detail = "\(env.label) account · epic \(order.epic)"
                if let s = order.stopLevel { detail += "\nStop: \(Fmt.level(s))" }
                if let t = order.profitLevel { detail += "\nLimit: \(Fmt.level(t))" }
                if env == .live { detail += "\n\nThis opens a REAL position with real money." }
                alert.informativeText = detail
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Place \(order.direction) Order")
                alert.buttons.last?.hasDestructiveAction = env == .live
                guard alert.runModal() == .alertSecondButtonReturn else { return }

                let c = try await client.openPosition(epic: order.epic, direction: order.direction,
                                                      size: order.size, stopLevel: order.stopLevel,
                                                      profitLevel: order.profitLevel, env: env, creds: creds)
                report(confirmation: c, action: order.direction)
            } catch {
                showError(error)
            }
            refresh()
        }
    }

    // MARK: - Feedback

    private func report(confirmation: DealConfirmation, action: String) {
        let status = (confirmation.dealStatus ?? confirmation.status ?? "UNKNOWN").uppercased()
        if status == "ACCEPTED" || status == "OPENED" || status == "CLOSED" {
            showMessage("\(action) accepted", [confirmation.epic, confirmation.size.map { "size \(Fmt.size($0))" },
                                               confirmation.level.map { "@ \(Fmt.level($0))" }]
                .compactMap { $0 }.joined(separator: " · "))
        } else {
            showMessage("\(action) \(status.lowercased())", confirmation.reason ?? "No reason given by Capital.com.")
        }
    }

    private func showError(_ error: Error) {
        showMessage("Capital.com error", error.localizedDescription)
    }

    private func showMessage(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum Fmt {
    static func money(_ v: Double) -> String { String(format: "%.2f", v) }
    static func signed(_ v: Double) -> String { String(format: "%@%.2f", v >= 0 ? "+" : "−", abs(v)) }
    static func size(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }
    static func level(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.2f", v) : String(format: "%.4f", v)
    }
    // Column alignment inside the menu, which uses a monospaced font.
    static func pad(_ s: String, _ width: Int) -> String {
        let t = s.count > width - 1 ? String(s.prefix(width - 2)) + "…" : s
        return t + String(repeating: " ", count: max(1, width - t.count))
    }
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
