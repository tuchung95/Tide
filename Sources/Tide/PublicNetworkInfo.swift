import Foundation

/// Looks up the network's public-facing (WAN) IP and ISP name — the
/// address/carrier the outside internet actually sees, as opposed to the
/// machine's private LAN address. Neither can be derived locally; both come
/// from a single request to ipinfo.io over HTTPS. That request necessarily
/// reveals your public IP to that third party, so it's only fetched once
/// per launch (retried on the next menu open if it failed), not on every
/// menu open.
enum PublicNetworkInfo {

    struct Info {
        var ip: String
        var ispName: String?
    }

    static func fetch(completion: @escaping (Info?) -> Void) {
        guard let url = URL(string: "https://ipinfo.io/json") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = json["ip"] as? String
            else {
                completion(nil)
                return
            }
            let ispName = (json["org"] as? String).map(Self.strippingASNPrefix)
            completion(Info(ip: ip, ispName: ispName))
        }.resume()
    }

    /// ipinfo.io returns "org" as e.g. "AS45899 VNPT Corp"; drop the ASN
    /// prefix to leave just the readable ISP name.
    private static func strippingASNPrefix(from org: String) -> String {
        guard let range = org.range(of: #"^AS\d+\s+"#, options: .regularExpression) else {
            return org
        }
        return String(org[range.upperBound...])
    }
}
