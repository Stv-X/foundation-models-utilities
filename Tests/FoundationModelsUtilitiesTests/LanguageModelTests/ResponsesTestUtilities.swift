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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

func makeResponsesMockModel(
  name: String = "test-model",
  headers: [String: String] = [:],
  supportsGuidedGeneration: Bool = true
) -> ResponsesLanguageModel {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [ResponsesMockSSEProtocol.self]
  var model = ResponsesLanguageModel(
    name: name,
    url: URL(string: "https://mock-responses.test/v1")!,
    additionalHeaders: headers,
    supportsGuidedGeneration: supportsGuidedGeneration
  )
  model.urlSession = URLSession(configuration: config)
  return model
}

func capturedResponsesRequest() throws -> URLRequest {
  try #require(ResponsesMockSSEProtocol.lastRequest)
}

func responsesRequestBody() throws -> [String: Any] {
  let request = try capturedResponsesRequest()
  let body = try #require(request.httpBody)
  return try JSONSerialization.jsonObject(with: body) as! [String: Any]
}
