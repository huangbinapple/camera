import Foundation
import simd

struct LUTFilter: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let cubeSize: Int
    let cubeData: Data
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
}
