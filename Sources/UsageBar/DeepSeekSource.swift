import Foundation

/// Result of one DeepSeek endpoint call: the balance row plus any VPS
/// telemetry carried in the same response (SPEC §8).
struct DeepSeekOutcome {
    var row: UsageRow
    /// Balance in the display currency (SPEC §13), for the menu bar title (§12).
    var balance: Money?
    /// Parsed `"vps"` object, when present.
    var vps: VPSStatus?
    /// Parsed `"vps"."billing"` block, when present (SPEC §9).
    var billing: VPSBilling?
    /// Whether an endpoint URL + token are configured.
    var vpsConfigured: Bool
    /// Why VPS telemetry is missing, when it is (for the popover fallback).
    var vpsNote: String?
}

/// Row 5 — DeepSeek API balance (STUB), plus the VPS telemetry section (SPEC §8).
///
/// If an endpoint URL and token are configured, performs a single GET with a
/// bearer token and parses both `balance_infos` and the optional `vps` object;
/// otherwise shows the manual balance or "not set". The balance is shown in the
/// display currency (SPEC §13). The token is never logged.
final class DeepSeekSource: UsageSource {
    let id = "deepseek"

    func makeRow(settings: Settings, now: Date) -> UsageRow {
        evaluate(settings: settings, now: now, fx: FX.make(settings: settings, rates: nil)).row
    }

    func evaluate(settings: Settings, now: Date, fx: FX) -> DeepSeekOutcome {
        let endpoint = settings.deepseekEndpointURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = settings.deepseekToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !endpoint.isEmpty, !token.isEmpty, let url = URL(string: endpoint) else {
            return DeepSeekOutcome(
                row: manualRow(settings: settings, fx: fx, note: nil),
                balance: settings.manualDeepseekBalance.map { Money($0, "USD") },
                vps: nil,
                billing: nil,
                vpsConfigured: false,
                vpsNote: nil
            )
        }

        switch fetch(url: url, token: token) {
        case .success(let json):
            let balance = parseBalance(json)
            let vpsObject = findValue(forKey: "vps", in: json)
            let vps = VPSStatus.parse(vpsObject)
            let billing = VPSBilling.parse((vpsObject as? [String: Any])?["billing"])
            let row = balance.value.map { balanceRow($0, fx: fx, now: now) }
                ?? manualRow(settings: settings, fx: fx, note: balance.note)
            return DeepSeekOutcome(
                row: row,
                balance: balance.value ?? settings.manualDeepseekBalance.map { Money($0, "USD") },
                vps: vps,
                billing: billing,
                vpsConfigured: true,
                vpsNote: vps == nil ? "no vps data in response" : nil
            )
        case .failure(let message):
            return DeepSeekOutcome(
                row: manualRow(settings: settings, fx: fx, note: message),
                balance: settings.manualDeepseekBalance.map { Money($0, "USD") },
                vps: nil,
                billing: nil,
                vpsConfigured: true,
                vpsNote: message
            )
        }
    }

    /// The live balance row shown on success. A prepaid top-up balance, so it
    /// stays in the currency it was topped up in rather than the display currency.
    func balanceRow(_ balance: Money, fx: FX, now: Date) -> UsageRow {
        UsageRow(
            id: id,
            title: "DeepSeek API",
            value: formatMoney(balance),
            footnote: "balance",
            tag: .live,
            updated: now
        )
    }

    /// Manual fallback (or "not set") shown when the balance is unavailable.
    func manualRow(settings: Settings, fx: FX, note: String?) -> UsageRow {
        let manual = settings.manualDeepseekBalance
        let value = manual.map { formatMoney(Money($0, "USD")) } ?? "not set"
        return UsageRow(
            id: id,
            title: "DeepSeek API",
            value: value,
            footnote: note ?? "manual balance",
            tag: manual == nil ? .none : .manual,
            updated: nil
        )
    }

    // MARK: - Fetch

    private enum FetchResult {
        case success([String: Any])
        case failure(String)
    }

    private func fetch(url: URL, token: String) -> FetchResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: FetchResult = .failure("no response")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil {
                result = .failure("request failed")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure("HTTP \(http.statusCode)")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure("unreadable response")
                return
            }
            result = .success(json)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return .failure("timed out")
        }
        session.finishTasksAndInvalidate()
        return result
    }

    /// Extracts the USD total from `balance_infos`, or a reason it is missing.
    private func parseBalance(_ json: [String: Any]) -> (value: Money?, note: String?) {
        guard let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            return (nil, "no balance_infos")
        }
        let info = infos.first(where: { ($0["currency"] as? String)?.uppercased() == "USD" })
            ?? infos.first(where: { ($0["currency"] as? String)?.isEmpty == false && doubleValue($0["total_balance"]) != nil })
        guard let info, let currency = info["currency"] as? String,
              let total = doubleValue(info["total_balance"]), total.isFinite else {
            return (nil, "no total_balance")
        }
        return (Money(total, currency), nil)
    }
}
