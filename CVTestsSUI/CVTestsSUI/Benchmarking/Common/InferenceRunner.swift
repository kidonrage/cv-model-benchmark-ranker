//
//  InferenceRunner.swift
//  CVTestsSUI
//
//  Created by Vlad Eliseev on 17.01.2026.
//

import CoreML
import Vision

func measureInference(block: () throws -> Void) rethrows -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    let end = CFAbsoluteTimeGetCurrent()
    return (end - start) * 1000 // миллисекунды
}
