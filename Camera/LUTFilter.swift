import Foundation

struct LUTFilter: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let cubeSize: Int
    let cubeData: Data
}
