import DesklogCore
import Foundation

struct ConfigurationStore {
    private let key = "desklog.configuration.v1"

    func load() -> DesklogConfiguration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configuration = try? JSONDecoder().decode(DesklogConfiguration.self, from: data) else {
            return DesklogConfiguration()
        }
        return configuration
    }

    func save(_ configuration: DesklogConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
