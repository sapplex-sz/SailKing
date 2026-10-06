#!/usr/bin/env swift
// Run: xcrun swift scripts/probe-translation.swift > build/translation-probe.json
// Uses only the fixed, fictional examples below. Never requests model downloads,
// reads user documents/clipboard, or calls a third-party API.
import Foundation
import Translation

struct SupportedLanguage: Encodable {
    let identifier: String
    let englishName: String
}

struct PairResult: Encodable {
    let source: String
    let target: String
    let sample: String
    var availability: String
    var translationAttempted = false
    var outcome = "skipped"
    var reason: String?
    var sessionCanRequestDownloads: Bool?
    var output: String?
    var reportedSource: String?
    var reportedTarget: String?
    var translationDurationMilliseconds: Int?
    var errorDomain: String?
    var errorCode: Int?
}

struct ProbeReport: Encodable {
    let schemaVersion = 1
    let timestamp: String
    let operatingSystem: String
    let strategy = "system-default"
    let userTextRead = false
    let downloadRequested = false
    let fixturesAreFictional = true
    var supportedLanguages: [SupportedLanguage] = []
    var pairs: [PairResult] = []
    var limitation: String?
}

func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

@available(macOS 26.0, *)
@MainActor
func runProbe() async -> ProbeReport {
    var report = ProbeReport(
        timestamp: timestamp(),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
    )
    let availability = LanguageAvailability()
    let english = Locale(identifier: "en_US")
    report.supportedLanguages = await availability.supportedLanguages.map { language in
        let identifier = language.minimalIdentifier
        return SupportedLanguage(
            identifier: identifier,
            englishName: english.localizedString(forIdentifier: identifier) ?? identifier
        )
    }.sorted { $0.identifier < $1.identifier }

    let fixtures: [(String, String, String)] = [
        ("fr", "ja", "Bonjour, la commande DEMO-482 contient deux articles. Merci de confirmer votre adresse de livraison."),
        ("ja", "fr", "ありがとうございます。ご注文番号DEMO-531の商品を明日発送します。"),
        ("es", "de", "Hola, el pedido DEMO-735 incluye tres artículos. Confirme la dirección de entrega, por favor."),
        ("en", "zh-Hans", "Hello, order DEMO-216 contains two blue notebooks. Please confirm the delivery address."),
        ("zh-Hans", "en", "您好，示例订单 DEMO-908 包含两本蓝色笔记本。请确认收货地址。")
    ]
    for (sourceIdentifier, targetIdentifier, sample) in fixtures {
        let source = Locale.Language(identifier: sourceIdentifier)
        let target = Locale.Language(identifier: targetIdentifier)
        let status = await availability.status(from: source, to: target)
        var result = PairResult(
            source: sourceIdentifier, target: targetIdentifier,
            sample: sample, availability: "unknown"
        )
        switch status {
        case .unsupported:
            result.availability = "unsupported"
            result.reason = "The framework does not support this language pair on this device."
        case .supported:
            result.availability = "supported"
            result.reason = "Models are not installed. This probe never requests downloads."
        case .installed:
            result.availability = "installed"
            let session = TranslationSession(installedSource: source, target: target)
            result.sessionCanRequestDownloads = session.canRequestDownloads
            // Fail closed if a future API changes the installed-only initializer's policy.
            guard !session.canRequestDownloads else {
                result.reason = "Skipped because this session unexpectedly permits model downloads."
                report.pairs.append(result)
                continue
            }
            result.translationAttempted = true
            let started = Date()
            do {
                let response = try await session.translate(sample)
                result.output = response.targetText
                result.reportedSource = response.sourceLanguage.minimalIdentifier
                result.reportedTarget = response.targetLanguage.minimalIdentifier
                if response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.outcome = "empty-output"
                    result.reason = "The real framework returned an empty translation."
                } else {
                    result.outcome = "translated"
                }
            } catch {
                let detail = error as NSError
                result.outcome = "failed"
                result.reason = detail.localizedDescription
                result.errorDomain = detail.domain
                result.errorCode = detail.code
            }
            result.translationDurationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        @unknown default:
            result.reason = "The framework returned a status unknown to this SDK."
        }
        report.pairs.append(result)
    }
    report.limitation = "A translated result proves only this fixed sample ran on this device. It is not a translation-quality or UI compatibility certification. Supported without installed is not a successful translation."
    return report
}

let report: ProbeReport
if #available(macOS 26.0, *) {
    report = await runProbe()
} else {
    report = ProbeReport(
        timestamp: timestamp(),
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        limitation: "macOS 26 or newer is required for installed-model translation without a UI. No translation was attempted."
    )
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(report))
FileHandle.standardOutput.write(Data("\n".utf8))
