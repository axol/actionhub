import Foundation

enum SoundGenerationError: Error {
    case requestFailed
}

struct SoundGenerator {
    func generate(prompt: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/sound-generation")!)
        request.httpMethod = "POST"
        request.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": prompt, "prompt_influence": 0.85])
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SoundGenerationError.requestFailed
        }
        return responseData
    }
}
