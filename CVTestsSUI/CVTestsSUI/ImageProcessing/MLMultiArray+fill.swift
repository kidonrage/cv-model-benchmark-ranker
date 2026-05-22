//
//  MLMultiArray+fill.swift
//  CVTestsSUI
//
//  Created by Vlad Eliseev on 17.01.2026.
//

import CoreML

extension MLMultiArray {
    func fill(with value: Float) {
        switch dataType {
        case .float32:
            let pointer = dataPointer.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count {
                pointer[index] = value
            }
        case .float16:
            let pointer = dataPointer.bindMemory(to: Float16.self, capacity: count)
            let converted = Float16(value)
            for index in 0..<count {
                pointer[index] = converted
            }
        default:
            for index in 0..<count {
                self[index] = NSNumber(value: value)
            }
        }
    }
}
