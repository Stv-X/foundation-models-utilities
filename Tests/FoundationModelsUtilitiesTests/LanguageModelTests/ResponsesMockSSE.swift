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

// Intercepts requests to "mock-responses.test" and returns canned SSE
// responses, letting us test the full ResponsesLanguageModel pipeline without
// a network. This is deliberately separate from `MockSSEProtocol` (used by
// the ChatCompletionsTests suite) so the two suites never race on shared
// static state when Swift Testing runs them in parallel.
final class ResponsesMockSSEProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (statusCode: Int, data: Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func reset() {
    handler = nil
    lastRequest = nil
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "mock-responses.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    // URLSession converts httpBody to httpBodyStream before passing to
    // protocol handlers; drain it back into httpBody so handlers and
    // lastRequest see consistent data.
    var normalizedRequest = request
    if let stream = request.httpBodyStream {
      stream.open()
      var bodyData = Data()
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: 4096)
        if n > 0 { bodyData.append(buffer, count: n) }
      }
      stream.close()
      normalizedRequest.httpBody = bodyData
    }
    Self.lastRequest = normalizedRequest
    let (statusCode, data) = Self.handler?(normalizedRequest) ?? (200, Data())
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"],
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

// Builders for the OpenAI Responses API SSE event format. Each event is
// emitted as an `event:` line plus a `data:` line whose JSON `type` field
// matches the event name - the production parser dispatches on that `type`
// field, so these streams exercise the same code path the real endpoint
// drives.
enum ResponsesMockSSE {
  struct Usage {
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int? = nil
    var reasoningTokens: Int? = nil
  }

  // Emits an SSE block per `(type, payload)`. The `type` field is injected
  // into each payload's JSON.
  static func events(_ events: [(type: String, payload: [String: Any])]) -> Data {
    var lines = [String]()
    for event in events {
      var payload = event.payload
      payload["type"] = event.type
      let json = String(
        data: try! JSONSerialization.data(withJSONObject: payload),
        encoding: .utf8
      )!
      lines.append("event: \(event.type)")
      lines.append("data: \(json)")
      lines.append("")
    }
    return Data(lines.joined(separator: "\n").utf8)
  }

  // A text response built from streamed `response.output_text.delta` events,
  // framed by the usual lifecycle events. `usage` is attached to the terminal
  // `response.completed` event (nil => `"usage": null`).
  static func text(_ chunks: String...) -> Data {
    textChunks(chunks)
  }

  static func textChunks(_ chunks: [String], usage: Usage? = nil) -> Data {
    var events: [(type: String, payload: [String: Any])] = []
    events.append(
      ("response.created", ["response": responseBody(status: "in_progress", usage: nil)])
    )
    events.append(
      (
        "response.output_item.added",
        [
          "output_index": 0,
          "item": [
            "type": "message",
            "id": "msg_1",
            "status": "in_progress",
            "role": "assistant",
            "content": [] as [Any],
          ]
        ]
      )
    )
    for chunk in chunks {
      events.append(
        (
          "response.output_text.delta",
          [
            "output_index": 0,
            "content_index": 0,
            "item_id": "msg_1",
            "delta": chunk
          ]
        )
      )
    }
    events.append(
      (
        "response.output_item.done",
        [
          "output_index": 0,
          "item": [
            "type": "message",
            "id": "msg_1",
            "status": "completed",
            "role": "assistant",
            "content": [
              ["type": "output_text", "text": chunks.joined(), "annotations": [] as [Any]]
            ]
          ]
        ]
      )
    )
    events.append(
      ("response.completed", ["response": responseBody(status: "completed", usage: usage)])
    )
    return Self.events(events)
  }

  // Reasoning summary deltas followed by text deltas, terminating with
  // `response.completed`.
  static func reasoningAndText(
    reasoningChunks: [String],
    textChunks: [String],
    usage: Usage? = nil
  ) -> Data {
    var events: [(type: String, payload: [String: Any])] = []
    for chunk in reasoningChunks {
      events.append(
        (
          "response.reasoning_summary_text.delta",
          [
            "output_index": 0,
            "summary_index": 0,
            "item_id": "rs_1",
            "delta": chunk
          ]
        )
      )
    }
    for chunk in textChunks {
      events.append(
        (
          "response.output_text.delta",
          [
            "output_index": 1,
            "content_index": 0,
            "item_id": "msg_1",
            "delta": chunk
          ]
        )
      )
    }
    events.append(
      ("response.completed", ["response": responseBody(status: "completed", usage: usage)])
    )
    return Self.events(events)
  }

  // A single function tool call: `output_item.added` (carrying `call_id` and
  // `name`), streamed argument deltas, then `output_item.done` and
  // `response.completed`.
  static func toolCall(
    id: String,
    callId: String,
    name: String,
    argumentChunks: [String]
  ) -> Data {
    var events: [(type: String, payload: [String: Any])] = []
    events.append(
      (
        "response.output_item.added",
        [
          "output_index": 0,
          "item": [
            "type": "function_call",
            "id": id,
            "call_id": callId,
            "name": name,
            "arguments": "",
            "status": "in_progress"
          ]
        ]
      )
    )
    for chunk in argumentChunks {
      events.append(
        (
          "response.function_call_arguments.delta",
          ["output_index": 0, "item_id": id, "delta": chunk]
        )
      )
    }
    events.append(
      (
        "response.function_call_arguments.done",
        [
          "output_index": 0,
          "item_id": id,
          "arguments": argumentChunks.joined(),
          "name": name
        ]
      )
    )
    events.append(
      (
        "response.output_item.done",
        [
          "output_index": 0,
          "item": [
            "type": "function_call",
            "id": id,
            "call_id": callId,
            "name": name,
            "arguments": argumentChunks.joined(),
            "status": "completed"
          ]
        ]
      )
    )
    events.append(
      ("response.completed", ["response": responseBody(status: "completed", usage: nil)])
    )
    return Self.events(events)
  }

  // Several function calls emitted in parallel, each on its own `output_index`.
  static func parallelToolCalls(
    _ calls: [(id: String, callId: String, name: String, arguments: String)]
  ) -> Data {
    var events: [(type: String, payload: [String: Any])] = []
    for (index, call) in calls.enumerated() {
      events.append(
        (
          "response.output_item.added",
          [
            "output_index": index,
            "item": [
              "type": "function_call",
              "id": call.id,
              "call_id": call.callId,
              "name": call.name,
              "arguments": "",
              "status": "in_progress"
            ]
          ]
        )
      )
      events.append(
        (
          "response.function_call_arguments.delta",
          ["output_index": index, "item_id": call.id, "delta": call.arguments]
        )
      )
      events.append(
        (
          "response.output_item.done",
          [
            "output_index": index,
            "item": [
              "type": "function_call",
              "id": call.id,
              "call_id": call.callId,
              "name": call.name,
              "arguments": call.arguments,
              "status": "completed"
            ]
          ]
        )
      )
    }
    events.append(
      ("response.completed", ["response": responseBody(status: "completed", usage: nil)])
    )
    return Self.events(events)
  }

  // Returns a handler that serves `toolCallData` until the request carries a
  // `function_call_output` input item (i.e. the tool result is being sent
  // back), then serves `textResponse`. Mirrors `MockSSE.toolCallThenText`.
  static func toolCallThenText(
    toolCallData: Data,
    textResponse: String
  ) -> (URLRequest) -> (statusCode: Int, data: Data) {
    { request in
      let body = request.httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      }
      let input = body?["input"] as? [[String: Any]]
      let hasToolOutput =
        input?.contains {
          $0["type"] as? String == "function_call_output"
        } ?? false

      if hasToolOutput {
        return (200, ResponsesMockSSE.text(textResponse))
      } else {
        return (200, toolCallData)
      }
    }
  }

  // A top-level `error` SSE event.
  static func apiError(message: String) -> Data {
    events([("error", ["message": message, "code": "server_error"])])
  }

  // A terminal `response.failed` event carrying `response.error`.
  static func failed(message: String) -> Data {
    events(
      [
        (
          "response.failed",
          [
            "response": [
              "id": "resp_1",
              "status": "failed",
              "error": ["code": "server_error", "message": message],
              "usage": NSNull()
            ]
          ]
        )
      ]
    )
  }

  private static func responseBody(status: String, usage: Usage?) -> [String: Any] {
    var body: [String: Any] = ["id": "resp_1", "status": status]
    if let usage {
      var usageObj: [String: Any] = [
        "input_tokens": usage.inputTokens,
        "output_tokens": usage.outputTokens,
        "total_tokens": usage.inputTokens + usage.outputTokens
      ]
      if let cached = usage.cachedTokens {
        usageObj["input_tokens_details"] = ["cached_tokens": cached]
      }
      if let reasoning = usage.reasoningTokens {
        usageObj["output_tokens_details"] = ["reasoning_tokens": reasoning]
      }
      body["usage"] = usageObj
    } else {
      body["usage"] = NSNull()
    }
    return body
  }
}
