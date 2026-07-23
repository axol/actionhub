#!/usr/bin/env ruby
require "rbnacl"
require "base64"
require "json"
require "openssl"

response_blob = ARGV.shift || raise("Usage: verify_response.rb <response_blob_or_path>")
response_blob = File.read(response_blob).strip if File.exist?(response_blob)

vectors = JSON.parse(File.read(File.expand_path("../Tests/Fixtures/vectors.json", __dir__)))
agent_signing_key = RbNaCl::SigningKey.new(Base64.strict_decode64(vectors["agent_seed"]))
phone_public_key = RbNaCl::VerifyKey.new(Base64.strict_decode64(vectors["phone_public_key"]))

opened = RbNaCl::Boxes::Sealed.from_private_key(agent_signing_key.to_curve25519_private_key)
                              .open(Base64.strict_decode64(response_blob))
envelope = JSON.parse(opened)

raise "sender mismatch" unless envelope["sender_public_key"] == vectors["phone_public_key"]

phone_public_key.verify(Base64.strict_decode64(envelope["signature"]), envelope["payload"].b)
response_payload = JSON.parse(envelope["payload"])

raise "envelope_type" unless response_payload["envelope_type"] == "response"
raise "request_id mismatch" unless response_payload["request_id"] == vectors["request_id"]
raise "request_payload envelope_type" unless response_payload.dig("request_payload", "envelope_type") == "request"

computed = OpenSSL::HMAC.hexdigest("SHA256", vectors["hmac_key"],
                                   JSON.generate(response_payload["request_payload"], sort_keys: true))
raise "HMAC mismatch" unless computed == response_payload["request_id"]

if (p256_public_key_path = ARGV.shift)
  spki_prefix = ["3059301306072a8648ce3d020106082a8648ce3d030107034200"].pack("H*")
  signature_base64 = response_payload["biometric_signature"] || raise("biometric signature required but missing")
  button_value = response_payload.dig("response", "button", "value").to_s
  message = ["actionhub-biometric-v1", response_payload["request_id"], button_value,
             response_payload["timestamp"].to_s, (response_payload["utterances"] || []).first.to_s].join("\n")
  public_key = OpenSSL::PKey.read(spki_prefix + Base64.strict_decode64(File.read(p256_public_key_path).strip))
  verified = public_key.verify(OpenSSL::Digest.new("SHA256"), Base64.strict_decode64(signature_base64), message)
  raise "biometric signature INVALID" unless verified
  puts "biometric signature VALID"
end

puts "VALID answer: #{response_payload['response'].inspect} at #{response_payload['timestamp']} utterances=#{response_payload['utterances'].inspect}"
