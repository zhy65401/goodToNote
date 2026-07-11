//
//  FXRateProviding.swift
//  GoodToNote
//
//  GN-004 / GN-024 — FX rate source abstraction + live implementation. The protocol
//  is injected into CurrencyConverter so unit tests can supply a mock; the real
//  OpenERAPIProvider fetches "1 foreign unit = X <base>" from open.er-api.com
//  (free, no API key, daily updates). https / default ATS-compliant.
//  GN-024: generalized from a hardcoded SGD base to ANY configurable base — one
//  `latest/{base}` call returns the full table relative to `base`, symmetric to the
//  old SGD-only code.
//

import Foundation

/// Fetches "1 unit of `currencyCode` = X units of `base`". Throws on network / parse failure.
protocol FXRateProviding {
    func rate(for currencyCode: String, base: String) async throws -> Decimal
}

enum FXRateError: Error {
    case badResponse
    case rateNotFound(String)
    case invalidRate
}

/// Live provider backed by open.er-api.com (no key, configurable base).
/// We request `latest/<base>` once → `.rates[FOREIGN]` is "1 base = N FOREIGN", so
/// "1 FOREIGN = 1/N base". This single call also lets us derive any currency.
/// GN-024: the endpoint is built per-base at call time (the API mirrors the old
/// SGD behaviour for any base code).
struct OpenERAPIProvider: FXRateProviding {
    let session: URLSession
    /// Endpoint template producing `https://open.er-api.com/v6/latest/<base>`.
    let endpoint: (String) -> URL

    init(session: URLSession = .shared,
         endpoint: @escaping (String) -> URL = { base in
            URL(string: "https://open.er-api.com/v6/latest/\(base.uppercased())")!
         }) {
        self.session = session
        self.endpoint = endpoint
    }

    private struct Response: Decodable {
        let result: String
        let base_code: String?
        let rates: [String: Double]
    }

    func rate(for currencyCode: String, base: String) async throws -> Decimal {
        let code = currencyCode.uppercased()
        let baseCode = base.uppercased()
        if code == baseCode { return 1 }

        var req = URLRequest(url: endpoint(baseCode))
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FXRateError.badResponse
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.result == "success" else { throw FXRateError.badResponse }
        // rates[code] = how many <code> per 1 base. We want base per 1 <code> = 1 / that.
        guard let perBase = decoded.rates[code], perBase > 0 else {
            throw FXRateError.rateNotFound(code)
        }
        let rate = Decimal(1.0 / perBase)
        guard rate > 0 else { throw FXRateError.invalidRate }
        return rate
    }

    /// Fetch the WHOLE rate table relative to `base` in one call, as
    /// "1 unit of code = N units of base" (base itself = 1). Used by the
    /// base-currency change recompute (GN-024) so all currencies come from a
    /// single network round-trip. Throws on network / parse failure.
    func fullTable(base: String) async throws -> [String: Decimal] {
        let baseCode = base.uppercased()
        var req = URLRequest(url: endpoint(baseCode))
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FXRateError.badResponse
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.result == "success" else { throw FXRateError.badResponse }
        // decoded.rates[code] = "1 base = N code" → invert to "1 code = 1/N base".
        var table: [String: Decimal] = [baseCode: 1]
        for (code, perBase) in decoded.rates where perBase > 0 {
            table[code.uppercased()] = Decimal(1.0 / perBase)
        }
        return table
    }
}
