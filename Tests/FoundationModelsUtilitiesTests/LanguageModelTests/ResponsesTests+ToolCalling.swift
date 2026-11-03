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
#if canImport(Darwin)
import Foundation
import FoundationModels
@testable import FoundationModelsUtilities
import Testing

extension ResponsesTests {
  @Suite struct ToolCalling {
    init() { ResponsesMockSSEProtocol.reset() }

    struct MockWeatherTool: Tool {
      let name = "get_weather"
      let description = "Get the weather for a location"

      @Generable
      struct Arguments {
        var location: String
      }

      func call(arguments: Arguments) async throws -> String {
        "Sunny in \(arguments.location)"
      }
    }

    @Test func `parses tool call with streamed arguments`() async throws {
      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: ResponsesMockSSE.toolCall(
          id: "fc_1",
          callId: "call_abc123",
          name: "get_weather",
          argumentChunks: [
            #"{"loc"#, #"ation""#, #":"New"#, #" York"}"#
          ]
        ),
        textResponse: "The weather is sunny"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "What's the weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)

      let calls = Array(toolCallEntries[0])
      #expect(calls.count == 1)
      #expect(calls[0].toolName == "get_weather")

      #expect(session.transcript.responseText == "The weather is sunny")
    }

    @Test func `parses tool call arguments from many small chunks`() async throws {
      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: ResponsesMockSSE.toolCall(
          id: "fc_2",
          callId: "call_granular",
          name: "get_weather",
          argumentChunks: [
            "{", #""l"#, #"oc"#, #"at"#, #"io"#, #"n""#, #":"#,
            #"""#, "S", "F", #"""#, "}"
          ]
        ),
        textResponse: "Done"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)
      let calls = Array(toolCallEntries[0])
      #expect(calls[0].toolName == "get_weather")
    }

    @Test func `parses parallel tool calls`() async throws {
      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: ResponsesMockSSE.parallelToolCalls([
          (
            id: "fc_a", callId: "call_1", name: "get_weather",
            arguments: #"{"location":"NYC"}"#
          ),
          (
            id: "fc_b", callId: "call_2", name: "get_weather",
            arguments: #"{"location":"LA"}"#
          )
        ]),
        textResponse: "Both done"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather in NYC and LA?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count >= 1)

      #expect(session.transcript.responseText == "Both done")
    }

    @Test func `correlates argument deltas by item_id when output_index is missing`() async throws {
      // Some proxies omit `output_index` on delta events; correlation must
      // fall back to `item_id`.
      let sseData = Data(
        [
          #"data: {"type":"response.created","response":{"status":"in_progress","usage":null}}"#,
          "",
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"","status":"in_progress"}}"#,
          "",
          #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"location\""}"#,
          "",
          #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":":\"NYC\"}"}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: sseData,
        textResponse: "NYC is sunny"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)
      let calls = Array(toolCallEntries[0])
      #expect(calls[0].toolName == "get_weather")
      let decodedArguments = try JSONSerialization.jsonObject(
        with: Data(calls[0].arguments.jsonString.utf8)
      ) as? [String: String]
      #expect(decodedArguments == ["location": "NYC"])
    }

    @Test func `repairs truncated arguments from the terminal done event`() async throws {
      // Deltas that were lost or truncated mid-stream are replaced by the
      // authoritative arguments carried by `function_call_arguments.done`.
      let sseData = Data(
        [
          #"data: {"type":"response.created","response":{"status":"in_progress","usage":null}}"#,
          "",
          #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"","status":"in_progress"}}"#,
          "",
          #"data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\"lo"}"#,
          "",
          #"data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","arguments":"{\"location\":\"NYC\"}"}"#,
          "",
          #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\"location\":\"NYC\"}","status":"completed"}}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: sseData,
        textResponse: "NYC is sunny"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)
      let calls = Array(toolCallEntries[0])
      #expect(calls[0].toolName == "get_weather")
      let decodedArguments = try JSONSerialization.jsonObject(
        with: Data(calls[0].arguments.jsonString.utf8)
      ) as? [String: String]
      #expect(decodedArguments == ["location": "NYC"])
    }

    @Test func `registers calls that appear only in output_item done`() async throws {
      // Servers that skip `output_item.added` and argument deltas entirely
      // still produce a usable tool call via the completed item.
      let sseData = Data(
        [
          #"data: {"type":"response.created","response":{"status":"in_progress","usage":null}}"#,
          "",
          #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\"location\":\"NYC\"}","status":"completed"}}"#,
          "",
          #"data: {"type":"response.completed","response":{"status":"completed","usage":null}}"#,
          "",
          "data: [DONE]",
          ""
        ].joined(separator: "\n").utf8
      )

      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: sseData,
        textResponse: "NYC is sunny"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather?")

      let toolCallEntries = session.transcript.compactMap(\.toolCalls)
      #expect(toolCallEntries.count == 1)
      let calls = Array(toolCallEntries[0])
      #expect(calls[0].toolName == "get_weather")
      let decodedArguments = try JSONSerialization.jsonObject(
        with: Data(calls[0].arguments.jsonString.utf8)
      ) as? [String: String]
      #expect(decodedArguments == ["location": "NYC"])
    }

    @Test func `includes tool definitions in request`() async throws {
      ResponsesMockSSEProtocol.handler = { _ in (200, ResponsesMockSSE.text("OK")) }

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "test")

      let body = try responsesRequestBody()
      let tools = try #require(body["tools"] as? [[String: Any]])
      #expect(tools.count >= 1)

      let tool = tools.first
      #expect(tool?["type"] as? String == "function")
      #expect(tool?["name"] as? String == "get_weather")
      #expect(tool?["strict"] as? Bool == true)
    }

    @Test func `round-trips call_id through function_call_output`() async throws {
      // The framework's tool-call id is the Responses `call_id`; the second
      // request must carry a `function_call_output` item whose `call_id`
      // matches the value streamed in `output_item.added`.
      ResponsesMockSSEProtocol.handler = ResponsesMockSSE.toolCallThenText(
        toolCallData: ResponsesMockSSE.toolCall(
          id: "fc_1",
          callId: "call_xyz",
          name: "get_weather",
          argumentChunks: [#"{"location":"NYC"}"#]
        ),
        textResponse: "It is sunny"
      )

      let session = LanguageModelSession(
        model: makeResponsesMockModel(),
        tools: [MockWeatherTool()]
      )
      let _ = try await session.respond(to: "Weather in NYC?")

      let body = try responsesRequestBody()
      let input = try #require(body["input"] as? [[String: Any]])
      let functionCall = try #require(
        input.first { $0["type"] as? String == "function_call" }
      )
      #expect(functionCall["call_id"] as? String == "call_xyz")
      #expect(functionCall["name"] as? String == "get_weather")

      let toolOutput = try #require(
        input.first { $0["type"] as? String == "function_call_output" }
      )
      #expect(toolOutput["call_id"] as? String == "call_xyz")
    }
  }
}
#endif
