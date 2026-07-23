import Foundation

enum ResponsePayloadBuilder {
    static func responsePayloadJson(requestId: String, rawRequestPayloadJson: String, buttonLabel: String, buttonValue: String, timestampMilliseconds: Int64, note: String?, biometricSignatureBase64: String? = nil) -> String {
        var utterancesJson = "[]"
        if let note, !note.isEmpty {
            utterancesJson = "[\(jsonEscapedString(note))]"
        }
        var biometricField = ""
        if let biometricSignatureBase64 {
            biometricField = ",\"biometric_signature\":\(jsonEscapedString(biometricSignatureBase64))"
        }
        return "{\"envelope_type\":\"response\"," +
            "\"type\":\"action_response\"," +
            "\"request_id\":\(jsonEscapedString(requestId))," +
            "\"request_payload\":\(rawRequestPayloadJson)," +
            "\"response\":{\"button\":{\"label\":\(jsonEscapedString(buttonLabel)),\"value\":\(jsonEscapedString(buttonValue))}}," +
            "\"timestamp\":\(timestampMilliseconds)," +
            "\"utterances\":\(utterancesJson)\(biometricField)}"
    }

    static func biometricSignedMessage(requestId: String, buttonValue: String, timestampMilliseconds: Int64, note: String?) -> Data {
        Data("actionhub-biometric-v1\n\(requestId)\n\(buttonValue)\n\(timestampMilliseconds)\n\(note ?? "")".utf8)
    }

    static func jsonEscapedString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }
}
