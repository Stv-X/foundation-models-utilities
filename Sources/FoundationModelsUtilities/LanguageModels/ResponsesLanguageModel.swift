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
public import Foundation
#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif
public import FoundationModels
#if canImport(CoreImage)
private import CoreImage
private import UniformTypeIdentifiers
#endif

/// A `LanguageModel` that talks to any OpenAI-compatible `/responses`
/// endpoint, streaming results back through the Foundation Models framework.
///
/// Use this model to drive a `LanguageModelSession` against any remote
/// service that implements the OpenAI Responses API.
///
/// ```swift
/// let model = ResponsesLanguageModel(
///     name: "your-model-name",
///     url: URL(string: "https://api.example.com")!,
///     additionalHeaders: ["Authorization": "Bearer \(apiKey)"]
/// )
///
/// let session = LanguageModelSession(model: model)
/// let response = try await session.respond(to: "Hello!")
/// ```
///
/// Unlike ``ChatCompletionsLanguageModel``, which maps the framework's
/// transcript onto `messages`, this model maps it onto the Responses API's
/// `input` items (messages, `function_call`, `function_call_output`,
/// `reasoning`) and translates the Responses SSE event stream
/// (`response.output_text.delta`, `response.function_call_arguments.delta`,
/// `response.completed`, and so on) back into framework channel events.
public struct ResponsesLanguageModel: Sendable, LanguageModel {
  /// The name of the underlying model, sent in the `model` field of each
  /// responses request.
  public var name: String

  /// The base URL of the responses endpoint. The path `/v1/responses` is
  /// appended automatically when the supplied URL does not already include a
  /// `v1` segment.
  public var url: URL

  /// Headers added to every outgoing request, merged on top of the defaults.
  /// Use this to provide authorization tokens or other vendor-specific
  /// headers.
  public var additionalHeaders: [String: String]

  public var supportsGuidedGeneration: Bool

  // Overridden in tests to inject a URLSession with mock protocol handlers.
  var urlSession: URLSession?

  /// Creates a responses language model.
  ///
  /// - Parameters:
  ///   - name: The model identifier sent in the `model` field of each
  ///     request.
  ///   - url: The base URL of the responses endpoint.
  ///   - additionalHeaders: Headers to merge on top of the defaults (for
  ///     example, an `Authorization` header).
  ///   - supportsGuidedGeneration: Whether the endpoint supports the
  ///     `text.format` JSON Schema field for structured output. Defaults to
  ///     `true`.
  ///   - urlSessionConfiguration: An optional `URLSessionConfiguration` used
  ///     to build the `URLSession` that drives requests. Use this to tune
  ///     timeouts, proxies, or other transport settings. When `nil`, an
  ///     ephemeral configuration is used.
  public init(
    name: String,
    url: URL,
    additionalHeaders: [String: String] = [:],
    supportsGuidedGeneration: Bool = true,
    urlSessionConfiguration: URLSessionConfiguration? = nil
  ) {
    self.name = name
    self.url = url
    self.additionalHeaders = additionalHeaders
    self.supportsGuidedGeneration = supportsGuidedGeneration
    self.urlSession = urlSessionConfiguration.map { URLSession(configuration: $0) }
  }

  // Implementation of LanguageModel Protocol
  public var capabilities: LanguageModelCapabilities {
    if supportsGuidedGeneration {
      LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
    } else {
      LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
    }
  }

  public var executorConfiguration: Executor.Configuration {
    Executor.Configuration(
      modelName: name,
      url: url,
      additionalHeaders: additionalHeaders,
      urlSession: urlSession
    )
  }

  /// An error returned by the responses endpoint in the body of a failed
  /// request, a streaming `error` event, or a `response.failed` event.
  ///
  /// Servers may populate any subset of the optional fields.
  public struct APIError: LocalizedError {
    /// A human-readable explanation of the error returned by the server.
    public var message: String

    /// The error category reported by the server (for example,
    /// `"invalid_request_error"`).
    public var type: String?

    /// The name of the request parameter associated with the error, when
    /// applicable.
    public var param: String?

    /// A short machine-readable error code provided by the server.
    public var code: String?

    /// Creates a new API error.
    ///
    /// - Parameters:
    ///   - message: A human-readable explanation of the error.
    ///   - type: The error category reported by the server.
    ///   - param: The request parameter associated with the error.
    ///   - code: A short machine-readable error code.
    public init(
      message: String,
      type: String? = nil,
      param: String? = nil,
      code: String? = nil
    ) {
      self.message = message
      self.type = type
      self.param = param
      self.code = code
    }
  }

  /// An error raised by ``ResponsesLanguageModel`` when a request cannot be
  /// issued or its response cannot be parsed.
  public enum RequestError: LocalizedError {
    /// The request could not be constructed because of invalid input. The
    /// associated value contains a human-readable description.
    case invalidRequest(_ description: String)

    /// A streaming event could not be decoded as a responses event.
    case invalidStreamData

    /// The endpoint returned a non-200 HTTP status code. The associated
    /// values contain the status code and the raw response body.
    case httpError(statusCode: Int, data: Data)

    public var errorDescription: String? {
      switch self {
      case .invalidRequest(let description):
        "Invalid request: \(description)"
      case .invalidStreamData:
        "Invalid streaming data received"
      case .httpError(let statusCode, let data):
        """
        HTTP error with status code \(statusCode):
        \(String(data: data, encoding: .utf8) ?? data.description)
        """
      }
    }
  }

  /// The wire format of an error envelope returned by the responses
  /// endpoint, used internally to decode error responses before raising them
  /// as ``APIError``.
  struct ErrorResponse: Codable, Sendable {
    var error: APIError

    struct APIError: Codable, Sendable {
      var message: String
      var type: String?
      var param: String?
      var code: String?
    }
  }

  public struct Executor: LanguageModelExecutor {
    public typealias Model = ResponsesLanguageModel
    private let configuration: Configuration

    public init(configuration: Configuration) {
      self.configuration = configuration
    }

    public struct Configuration: Hashable, Sendable {
      fileprivate let modelName: String
      fileprivate let url: URL
      fileprivate let additionalHeaders: [String: String]
      fileprivate let urlSession: URLSession?

      public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
        lhs.modelName == rhs.modelName
          && lhs.url == rhs.url
          && lhs.additionalHeaders == rhs.additionalHeaders
      }

      public func hash(into hasher: inout Hasher) {
        hasher.combine(modelName)
        hasher.combine(url)
        hasher.combine(additionalHeaders)
      }
    }

    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: ResponsesLanguageModel,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {

      // Caller-supplied headers override the defaults on conflict.
      let headers = [
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "User-Agent": Bundle.main.bundleIdentifier ?? "com.apple.FoundationModels"
      ].merging(
        configuration.additionalHeaders,
        uniquingKeysWith: { _, custom in custom }
      )

      // Tests inject a URLSession; production uses a fresh ephemeral one.
      let client = ResponsesClient(
        baseURL: configuration.url,
        headers: headers,
        session: configuration.urlSession ?? URLSession(configuration: .ephemeral)
      )

      // Translate the framework's request into the OpenAI-compatible wire format.
      let responseRequest = ResponsesClient.ResponseRequest(
        model: configuration.modelName,
        input: try convertedTranscript(request.transcript),
        temperature: request.generationOptions.temperature,
        topP: try request.generationOptions.samplingMode.map(topP),
        maxOutputTokens: request.generationOptions.maximumResponseTokens,
        tools: request.enabledToolDefinitions.map { tool in
          ResponsesClient.Tool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
          )
        },
        toolChoice: ResponsesClient.ResponseRequest.ToolChoice(
          mode: {
            switch request.generationOptions.toolCallingMode?.kind {
            case .allowed, .none: .auto
            case .required: .required
            case .disallowed: .none
            @unknown default: .auto
            }
          }()
        ),
        text: request.schema.map { schema in
          ResponsesClient.TextConfig(
            format: ResponsesClient.TextConfig.Format(
              name: schema.name,
              schema: schema
            )
          )
        }
      )

      // Stream the response back into the framework via `channel`.
      try await Self.processEvents(
        client.streamResponse(request: responseRequest),
        into: channel
      )
    }

    private static func processEvents<EventSequence: AsyncSequence>(
      _ events: EventSequence,
      into channel: LanguageModelExecutorGenerationChannel
    ) async throws where EventSequence.Element == ResponsesClient.StreamEvent {
      // Latched (call_id, name) per output_index for function calls. The
      // `response.output_item.added` event supplies them; argument deltas
      // arrive later keyed by `output_index`. `registered` tracks whether we
      // have already forwarded any `.toolCall` event for this call, so a
      // no-argument call can still be registered on `output_item.done`.
      var functionCalls: [Int: (callId: String, name: String, registered: Bool)] = [:]

      // Stable entryIDs per event type for the duration of this stream.
      // Without these, interleaved reasoning/response/toolCalls events would
      // split into multiple transcript entries - the framework only coalesces
      // consecutive events of the same type into the trailing entry.
      let responseEntryID = UUID().uuidString
      let reasoningEntryID = UUID().uuidString
      let toolCallsEntryID = UUID().uuidString

      for try await event in events {
        switch event.type {
        case "response.output_text.delta":
          if let delta = event.delta {
            await channel.send(
              .response(
                entryID: responseEntryID,
                action: .appendText(delta, tokenCount: 1)
              )
            )
          }

        // Reasoning summary deltas (gpt-5 family) and reasoning text deltas
        // (o-family) both stream the model's reasoning; route either to the
        // same reasoning transcript entry.
        case "response.reasoning_summary_text.delta",
          "response.reasoning_text.delta",
          "response.reasoning.delta":
          if let delta = event.delta {
            await channel.send(
              .reasoning(
                entryID: reasoningEntryID,
                action: .appendText(delta, tokenCount: 1)
              )
            )
          }

        case "response.output_item.added":
          if let item = event.item,
            item.type == "function_call",
            let outputIndex = event.outputIndex,
            let callId = item.callId, !callId.isEmpty,
            let name = item.name, !name.isEmpty
          {
            functionCalls[outputIndex] = (callId, name, false)
          }

        case "response.function_call_arguments.delta":
          if let outputIndex = event.outputIndex,
            let functionCall = functionCalls[outputIndex],
            let delta = event.delta
          {
            await channel.send(
              .toolCalls(
                entryID: toolCallsEntryID,
                action: .toolCall(
                  id: functionCall.callId,
                  name: functionCall.name,
                  action: .appendArguments(delta, tokenCount: 1)
                )
              )
            )
            functionCalls[outputIndex] =
              (functionCall.callId, functionCall.name, true)
          }

        case "response.output_item.done":
          if let item = event.item,
            item.type == "function_call",
            let outputIndex = event.outputIndex
          {
            // Latch name/call_id here too, in case `output_item.added` was
            // not emitted by the server.
            if functionCalls[outputIndex] == nil,
              let callId = item.callId, !callId.isEmpty,
              let name = item.name, !name.isEmpty
            {
              functionCalls[outputIndex] = (callId, name, false)
            }
            // Register calls that received no argument deltas (e.g. tools
            // with no parameters) so they still appear in the transcript.
            if var functionCall = functionCalls[outputIndex],
              !functionCall.registered
            {
              await channel.send(
                .toolCalls(
                  entryID: toolCallsEntryID,
                  action: .toolCall(
                    id: functionCall.callId,
                    name: functionCall.name,
                    action: .appendArguments("", tokenCount: 1)
                  )
                )
              )
              functionCall.registered = true
              functionCalls[outputIndex] = functionCall
            }
          }

        // Usage is carried by the terminal `response.completed` (and
        // `response.incomplete`) event. Forward it AFTER content so the
        // authoritative cumulative total overwrites `appendText`'s token
        // credits.
        case "response.completed", "response.incomplete":
          if let usage = event.response?.usage {
            await channel.send(
              .response(
                entryID: responseEntryID,
                action: .updateUsage(
                  input: .init(
                    totalTokenCount: usage.inputTokens ?? 0,
                    cachedTokenCount: usage.inputTokensDetails?.cachedTokens ?? 0
                  ),
                  output: .init(
                    totalTokenCount: usage.outputTokens ?? 0,
                    reasoningTokenCount: usage.outputTokensDetails?.reasoningTokens ?? 0
                  )
                )
              )
            )
          }

        case "error":
          throw ResponsesLanguageModel.APIError(
            message: event.message ?? "Unknown error",
            type: nil,
            param: event.param,
            code: event.code
          )

        case "response.failed":
          if let error = event.response?.error {
            throw ResponsesLanguageModel.APIError(
              message: error.message ?? "Response failed",
              type: nil,
              param: nil,
              code: error.code
            )
          }
          throw ResponsesLanguageModel.APIError(
            message: "Response failed with status \(event.response?.status ?? "failed")"
          )

        // response.created, response.in_progress, response.queued,
        // content_part.added/done, output_text.done, reasoning_summary_*,
        // built-in-tool events, etc. carry no data the framework needs.
        default:
          break
        }
      }
    }

    private func topP(_ sampling: GenerationOptions.SamplingMode) throws -> Double {
      switch sampling.kind {
      case .greedy:
        return 0

      case .randomTopK:
        throw ResponsesLanguageModel.RequestError.invalidRequest(
          "Top K sampling is not supported"
        )
      case .randomProbabilityThreshold(let threshold, let seed):
        guard seed == nil else {
          throw ResponsesLanguageModel.RequestError.invalidRequest(
            "Setting a random seed is not supported"
          )
        }
        return threshold
      @unknown default:
        throw ResponsesLanguageModel.RequestError.invalidRequest(
          "Unknown sampling mode \(sampling.kind) is not supported"
        )
      }
    }

    private func convertedTranscript(
      _ entries: some Collection<Transcript.Entry>
    ) throws -> [ResponsesClient.InputItem] {

      // Converts a single transcript segment into responses content parts.
      // `textPartType` is "input_text" for user/system/developer messages and
      // "output_text" for assistant messages, matching how the API itself
      // represents each role's content.
      func convertedContent(
        _ segments: some Collection<Transcript.Segment>,
        in entry: Transcript.Entry,
        textPartType: String
      ) throws -> ResponsesClient.MessageContent {
        var parts: [ResponsesClient.ContentPart] = []
        for segment in segments {
          switch segment {
          case .text(let text):
            parts.append(
              ResponsesClient.ContentPart(type: textPartType, text: text.content)
            )
          // Structured content is serialized to JSON text on the wire.
          case .structure(let structure):
            parts.append(
              ResponsesClient.ContentPart(
                type: textPartType,
                text: structure.content.jsonString
              )
            )
          case .attachment(let attachment):
            switch attachment.content {
            case .image(let image):
              #if canImport(CoreImage)
              // Images are inlined as base64 data URLs (JPEG).
              let base64String = image.cgImage.jpegData().base64EncodedString()
              let dataURL = "data:image/jpeg;base64,\(base64String)"
              parts.append(
                ResponsesClient.ContentPart(
                  type: "input_image",
                  imageURL: dataURL,
                  detail: "auto"
                )
              )
              #else
              guard let url = image.url else {
                throw LanguageModelError.unsupportedTranscriptContent(
                  LanguageModelError.UnsupportedTranscriptContent(
                    unsupportedContent: [entry],
                    debugDescription: "Image attachment without a URL is not supported by \(Self.self) on this platform."
                  )
                )
              }
              let dataURL: String
              if url.scheme == "data" {
                dataURL = url.absoluteString
              } else {
                let data = try Data(contentsOf: url)
                let base64String = data.base64EncodedString()
                dataURL = "data:image/jpeg;base64,\(base64String)"
              }
              parts.append(
                ResponsesClient.ContentPart(
                  type: "input_image",
                  imageURL: dataURL,
                  detail: "auto"
                )
              )
              #endif
            @unknown default:
              throw LanguageModelError.unsupportedTranscriptContent(
                LanguageModelError.UnsupportedTranscriptContent(
                  unsupportedContent: [entry],
                  debugDescription: "Attachment type not supported by \(Self.self)."
                )
              )
            }
          case .custom:
            throw LanguageModelError.unsupportedTranscriptContent(
              LanguageModelError.UnsupportedTranscriptContent(
                unsupportedContent: [entry],
                debugDescription: "Custom segments are not supported by \(Self.self)"
              )
            )

          @unknown default:
            throw LanguageModelError.unsupportedTranscriptContent(
              LanguageModelError.UnsupportedTranscriptContent(
                unsupportedContent: [entry],
                debugDescription: "Unknown segment type not supported by \(Self.self)"
              )
            )
          }
        }

        // Compact single-text-segment messages to a plain string content,
        // matching the API's string-or-array `content` union.
        if parts.count == 1,
          let only = parts.first,
          only.text != nil,
          only.imageURL == nil
        {
          return .text(only.text ?? "")
        }
        return .parts(parts)
      }

      // Joins text/structure segments into the string `output` of a
      // function_call_output item. Non-text segments are skipped.
      func convertedOutput(
        _ segments: some Collection<Transcript.Segment>
      ) -> String {
        var pieces: [String] = []
        for segment in segments {
          switch segment {
          case .text(let text):
            pieces.append(text.content)
          case .structure(let structure):
            pieces.append(structure.content.jsonString)
          case .attachment, .custom:
            continue
          @unknown default:
            continue
          }
        }
        return pieces.joined()
      }

      var items: [ResponsesClient.InputItem] = []

      // Translate each transcript entry into one or more responses input
      // items, preserving transcript order. Reasoning entries become
      // standalone `reasoning` items (the Responses API has no per-message
      // `reasoning_content` field).
      for entry in entries {
        switch entry {
        case .instructions(let instructions):
          // Instructions become system-role message items.
          items.append(
            ResponsesClient.InputItem(
              type: "message",
              role: "system",
              content: try convertedContent(
                instructions.segments,
                in: entry,
                textPartType: "input_text"
              )
            )
          )

        case .prompt(let prompt):
          items.append(
            ResponsesClient.InputItem(
              type: "message",
              role: "user",
              content: try convertedContent(
                prompt.segments,
                in: entry,
                textPartType: "input_text"
              )
            )
          )

        case .toolCalls(let toolCalls):
          // Each tool call becomes a `function_call` input item. The
          // framework's tool-call id is the Responses `call_id`, so a later
          // `function_call_output` round-trips via `toolOutput.id`.
          for call in toolCalls {
            items.append(
              ResponsesClient.InputItem(
                type: "function_call",
                callId: call.id,
                name: call.toolName,
                arguments: call.arguments.jsonString
              )
            )
          }

        case .toolOutput(let toolOutput):
          items.append(
            ResponsesClient.InputItem(
              type: "function_call_output",
              callId: toolOutput.id,
              output: convertedOutput(toolOutput.segments)
            )
          )

        case .response(let response):
          items.append(
            ResponsesClient.InputItem(
              type: "message",
              role: "assistant",
              content: try convertedContent(
                response.segments,
                in: entry,
                textPartType: "output_text"
              )
            )
          )

        case .reasoning(let reasoning):
          // Replay reasoning as a summary-only `reasoning` item. The framework
          // exposes only the summary text (no `encrypted_content`), so this
          // provides context without continuing a reasoning chain.
          let text = reasoning.segments.compactMap { segment -> String? in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
          }.joined()
          items.append(
            ResponsesClient.InputItem(
              type: "reasoning",
              summary: [ResponsesClient.SummaryPart(text: text)]
            )
          )

        @unknown default:
          continue
        }
      }

      return items
    }
  }
}

private struct ResponsesClient {
  let baseURL: URL
  let headers: [String: String]
  let session: URLSession

  func streamResponse(
    request: ResponseRequest
  ) -> AsyncThrowingStream<StreamEvent, Swift.Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try buildURLRequest(for: request)
          #if canImport(Darwin)
          let (stream, response) = try await session.bytes(for: urlRequest)
          let httpResponse = response as! HTTPURLResponse

          guard httpResponse.statusCode == 200 else {
            throw ResponsesLanguageModel.RequestError.httpError(
              statusCode: httpResponse.statusCode,
              data: try await stream.reduce(Data(), { $0 + [$1] })
            )
          }

          for try await line in stream.lines {
            if let event = try parseStreamLine(line) {
              continuation.yield(event)
            }
          }

          continuation.finish()
          #else
          let (data, response) = try await session.data(for: urlRequest)
          let httpResponse = response as! HTTPURLResponse

          guard httpResponse.statusCode == 200 else {
            throw ResponsesLanguageModel.RequestError.httpError(
              statusCode: httpResponse.statusCode,
              data: data
            )
          }

          let body = String(data: data, encoding: .utf8) ?? ""
          for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = try parseStreamLine(String(line)) {
              continuation.yield(event)
            }
          }

          continuation.finish()
          #endif

        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func buildURLRequest(for request: ResponseRequest) throws -> URLRequest {
    let isVersioned = baseURL.pathComponents.contains { component in
      component.wholeMatch(of: #/v\d+/#) != nil
    }
    let endpoint = isVersioned ? "/responses" : "/v1/responses"
    let url = baseURL.appendingPathComponent(endpoint)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    for (header, value) in headers {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }

    let encoder = JSONEncoder()
    urlRequest.httpBody = try encoder.encode(request)

    return urlRequest
  }

  func parseStreamLine(_ line: String) throws -> StreamEvent? {
    let trimmedLine = line.trimmingCharacters(in: .whitespaces)

    // Skip empty lines and comments. Non-data SSE field lines (`event:`,
    // `id:`, `retry:`) also fall through to the final `return nil` - the
    // event type is dispatched from the JSON `type` field on `data:` lines,
    // so the SSE `event:` header is optional.
    guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix(":") else {
      return nil
    }

    if trimmedLine.hasPrefix("data: ") {
      let jsonString = String(trimmedLine.dropFirst(6))  // Remove "data: "

      if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
        return nil
      }

      guard let jsonData = jsonString.data(using: .utf8) else {
        throw ResponsesLanguageModel.RequestError.invalidStreamData
      }

      let decoder = JSONDecoder()
      do {
        return try decoder.decode(StreamEvent.self, from: jsonData)
      } catch {
        if let response = try? decoder.decode(
          ResponsesLanguageModel.ErrorResponse.self,
          from: jsonData
        ) {
          throw ResponsesLanguageModel.APIError(
            message: response.error.message,
            type: response.error.type,
            param: response.error.param,
            code: response.error.code
          )
        }
        throw error
      }
    }

    return nil
  }

  struct ResponseRequest: Encodable {
    struct ToolChoice: Encodable {
      let mode: Mode

      enum Mode: String, Encodable {
        case auto
        case required
        case none
      }

      func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(mode)
      }
    }

    var model: String
    var input: [InputItem]
    var temperature: Double?
    var topP: Double?
    var maxOutputTokens: Int?
    var tools: [Tool]
    var toolChoice: ToolChoice
    var text: TextConfig?
    var stream = true
    // Stateless: replay the full transcript as `input` every turn and never
    // reference `previous_response_id`, so don't accumulate stored responses.
    var store = false

    private enum CodingKeys: String, CodingKey {
      case model
      case input
      case temperature
      case topP = "top_p"
      case maxOutputTokens = "max_output_tokens"
      case tools
      case toolChoice = "tool_choice"
      case text
      case stream
      case store
    }
  }

  struct InputItem: Encodable {
    var type: String
    var role: String? = nil
    var content: MessageContent? = nil
    var callId: String? = nil
    var name: String? = nil
    var arguments: String? = nil
    var output: String? = nil
    var summary: [SummaryPart]? = nil

    private enum CodingKeys: String, CodingKey {
      case type
      case role
      case content
      case callId = "call_id"
      case name
      case arguments
      case output
      case summary
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(type, forKey: .type)
      try container.encodeIfPresent(role, forKey: .role)
      try container.encodeIfPresent(callId, forKey: .callId)
      try container.encodeIfPresent(name, forKey: .name)
      try container.encodeIfPresent(arguments, forKey: .arguments)
      try container.encodeIfPresent(output, forKey: .output)
      try container.encodeIfPresent(summary, forKey: .summary)

      if let content {
        switch content {
        case .text(let text):
          try container.encode(text, forKey: .content)
        case .parts(let parts):
          try container.encode(parts, forKey: .content)
        }
      }
    }
  }

  enum MessageContent {
    case text(String)
    case parts([ContentPart])
  }

  struct ContentPart: Encodable {
    var type: String
    var text: String? = nil
    var imageURL: String? = nil
    var detail: String? = nil

    private enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
      case detail
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(type, forKey: .type)
      try container.encodeIfPresent(text, forKey: .text)
      try container.encodeIfPresent(imageURL, forKey: .imageURL)
      try container.encodeIfPresent(detail, forKey: .detail)
    }
  }

  struct SummaryPart: Encodable {
    var type = "summary_text"
    var text: String
  }

  struct Tool: Encodable {
    var type = "function"
    var name: String
    var description: String
    var parameters: GenerationSchema
    var strict = true
  }

  struct TextConfig: Encodable {
    var format: Format

    struct Format: Encodable {
      var type = "json_schema"
      var name: String
      var schema: GenerationSchema
      var strict = true
    }
  }

  /// A single decoded SSE event. All fields except `type` are optional; the
  /// decoder ignores unknown keys, so one envelope covers every event variant.
  /// Dispatch happens on `type` in `processEvents`.
  struct StreamEvent: Decodable {
    let type: String
    let delta: String?
    let text: String?
    let outputIndex: Int?
    let itemId: String?
    let item: OutputItem?
    let response: ResponseBody?
    // Top-level fields of the `error` event.
    let message: String?
    let code: String?
    let param: String?

    private enum CodingKeys: String, CodingKey {
      case type
      case delta
      case text
      case outputIndex = "output_index"
      case itemId = "item_id"
      case item
      case response
      case message
      case code
      case param
    }
  }

  /// An output item embedded in `response.output_item.added` / `.done`. Only
  /// the function-call fields are decoded; other item kinds are identified by
  /// `type` alone.
  struct OutputItem: Decodable {
    let type: String?
    let callId: String?
    let name: String?
    let arguments: String?

    private enum CodingKeys: String, CodingKey {
      case type
      case callId = "call_id"
      case name
      case arguments
    }
  }

  /// The response object embedded in lifecycle events
  /// (`response.created` / `.completed` / `.failed` / `.incomplete`).
  struct ResponseBody: Decodable {
    let status: String?
    let usage: Usage?
    let error: ResponseError?
  }

  struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let inputTokensDetails: TokenDetails?
    let outputTokensDetails: TokenDetails?

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
      case inputTokensDetails = "input_tokens_details"
      case outputTokensDetails = "output_tokens_details"
    }
  }

  struct TokenDetails: Decodable {
    let cachedTokens: Int?
    let reasoningTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
      case reasoningTokens = "reasoning_tokens"
    }
  }

  struct ResponseError: Decodable {
    let code: String?
    let message: String?
  }
}

#if canImport(CoreImage)
private extension CGImage {
  func jpegData() -> Data {
    let imageData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      /* data */ imageData,
      /* format */ UTType.jpeg.identifier as CFString,
      /* count */ 1,
      /* options */ nil
    )!
    CGImageDestinationAddImage(destination, self, nil)
    CGImageDestinationFinalize(destination)
    return Data(referencing: imageData)
  }
}
#endif
