//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ResponsesTests {
  @Suite struct Configuration {
    init() { ResponsesMockSSEProtocol.reset() }

    @Test func `stores provided properties`() {
      let url = URL(string: "https://api.example.com/v1")!
      let model = ResponsesLanguageModel(
        name: "foo",
        url: url,
        additionalHeaders: ["Authorization": "Bearer test"],
        supportsGuidedGeneration: false
      )
      #expect(model.name == "foo")
      #expect(model.url == url)
      #expect(model.additionalHeaders == ["Authorization": "Bearer test"])
      #expect(model.supportsGuidedGeneration == false)
    }

    @Test func `defaults to supporting guided generation`() {
      let model = makeResponsesMockModel()
      #expect(model.supportsGuidedGeneration == true)
    }

    @Test func `capabilities include guided generation when supported`() {
      let model = makeResponsesMockModel(supportsGuidedGeneration: true)
      #expect(model.capabilities.contains(.vision))
      #expect(model.capabilities.contains(.toolCalling))
      #expect(model.capabilities.contains(.reasoning))
      #expect(model.capabilities.contains(.guidedGeneration))
    }

    @Test func `capabilities exclude guided generation when not supported`() {
      let model = makeResponsesMockModel(supportsGuidedGeneration: false)
      #expect(model.capabilities.contains(.vision))
      #expect(model.capabilities.contains(.toolCalling))
      #expect(model.capabilities.contains(.reasoning))
      #expect(!model.capabilities.contains(.guidedGeneration))
    }
  }
}
