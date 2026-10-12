import AppKit

struct OrderRequest {
    let epic: String
    let name: String
    let direction: String   // BUY | SELL
    let size: Double
    let stopLevel: Double?
    let profitLevel: Double?
}

@MainActor
enum TradeDialogs {
    static func askSearchTerm(title: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. brent, gold, BTC, AAPL"
        if let last = UserDefaults.standard.string(forKey: "lastSearch") { field.stringValue = last }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Search Capital.com markets."
        alert.accessoryView = field
        alert.addButton(withTitle: "Search")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let term = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        UserDefaults.standard.set(term, forKey: "lastSearch")
        return term
    }

    static func askMarket(results: [MarketSearchResult]) -> MarketSearchResult? {
        let choices = Array(results.prefix(40))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for m in choices { popup.addItem(withTitle: "\(m.instrumentName ?? m.epic)  ·  \(m.epic)") }

        let alert = NSAlert()
        alert.messageText = "Pick a market"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let i = popup.indexOfSelectedItem
        return i >= 0 && i < choices.count ? choices[i] : nil
    }

    static func askOrder(results: [MarketSearchResult], env: TradingEnv) -> OrderRequest? {
        let width: CGFloat = 320
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 132))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 104, width: width, height: 26), pullsDown: false)
        let tradable = Array(results.prefix(40))
        for m in tradable {
            let price = m.offer.map { " · \(Fmt.level($0))" } ?? ""
            let status = (m.marketStatus ?? "").uppercased() == "TRADEABLE" ? "" : " · \(m.marketStatus ?? "")"
            popup.addItem(withTitle: "\(m.instrumentName ?? m.epic)\(price)\(status)")
        }
        view.addSubview(popup)

        func labelled(_ text: String, y: CGFloat, placeholder: String, value: String = "") -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: y, width: 96, height: 20)
            label.alignment = .right
            label.font = .systemFont(ofSize: 12)
            view.addSubview(label)
            let field = NSTextField(frame: NSRect(x: 104, y: y - 3, width: width - 104, height: 24))
            field.placeholderString = placeholder
            field.stringValue = value
            view.addSubview(field)
            return field
        }

        let lastSize = UserDefaults.standard.string(forKey: "lastSize") ?? ""
        let sizeField = labelled("Size", y: 70, placeholder: "contracts, e.g. 1", value: lastSize)
        let stopField = labelled("Stop level", y: 38, placeholder: "optional price")
        let limitField = labelled("Limit level", y: 6, placeholder: "optional price")

        let alert = NSAlert()
        alert.messageText = "Place order · \(env.label)"
        alert.informativeText = env == .live
            ? "Real money. Stop and limit are absolute price levels, not distances."
            : "Demo account. Stop and limit are absolute price levels, not distances."
        alert.accessoryView = view
        alert.addButton(withTitle: "Buy")
        alert.addButton(withTitle: "Sell")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = sizeField

        let response = alert.runModal()
        let direction: String
        switch response {
        case .alertFirstButtonReturn: direction = "BUY"
        case .alertSecondButtonReturn: direction = "SELL"
        default: return nil
        }

        guard popup.indexOfSelectedItem >= 0, popup.indexOfSelectedItem < tradable.count else { return nil }
        let market = tradable[popup.indexOfSelectedItem]

        guard let size = Double(sizeField.stringValue.trimmingCharacters(in: .whitespaces)), size > 0 else {
            let bad = NSAlert()
            bad.messageText = "Invalid size"
            bad.informativeText = "Enter a positive number of contracts."
            bad.runModal()
            return nil
        }
        UserDefaults.standard.set(sizeField.stringValue, forKey: "lastSize")

        return OrderRequest(
            epic: market.epic,
            name: market.instrumentName ?? market.epic,
            direction: direction,
            size: size,
            stopLevel: Double(stopField.stringValue.trimmingCharacters(in: .whitespaces)),
            profitLevel: Double(limitField.stringValue.trimmingCharacters(in: .whitespaces)))
    }
}
