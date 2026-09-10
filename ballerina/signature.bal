// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// AgentCard signature verification, per specification section 8.4.
//
// Implements the spec's canonicalize-and-verify procedure exactly as far
// as it is defined, and no further: JCS (RFC 8785) canonicalization,
// proto3 default-stripping, and JWS (RS256/ES256) verification. What it
// deliberately does not do is fetch a signing key from a card's `jku`
// (JWK Set URL) - per §8.4.3 step 2, that requires resolving and parsing
// a JWK Set, which neither reference SDK's own verifier does either:
// a2a-js's `verifyAgentCardSignature(retrievePublicKey)` and Python's
// `key_provider(kid, jku)` both hand key resolution to a caller-supplied
// callback. This module matches that shape - callers already doing their
// own key management (a truststore, a pinned key, their own jku fetch)
// are the common case, and the boundary is the same one every other A2A
// client library already drew.
//
// A prior version of this file was removed before release (issue #12)
// because it verified signatures over `AgentCard.toJsonString()` -
// Ballerina's own record serialization, not JCS - so it could only ever
// verify signatures computed over its own output, never a real signer's.
// This version fixes that at the root: canonicalization runs on the raw
// JSON exactly as received (see `fetchAgentCardBody`, client.bal), never
// on a parsed `AgentCard` record. A record carries every field's declared
// default whether or not the signer included it on the wire
// (`requestedExtensions = []`, `securitySchemes = {}`, ...), so
// canonicalizing the typed form would inject content the signer never
// signed and guarantee failure - the exact class of bug this module
// exists to avoid repeating.

import ballerina/crypto;
import ballerina/lang.array;

# Resolves the public key for one AgentCard signature entry.
#
# Called once per signature on the card (spec: verification succeeds if
# **any** signature verifies), so a card signed by multiple parties with
# different keys is handled correctly - each `kid` gets its own lookup.
#
# This library does not fetch `jku` itself (see the file header comment);
# `jku` is passed through only so an implementation that does want to
# resolve it can, matching the reference SDKs' key-provider shape.
#
# + kid - the `kid` (key ID) claim from the signature's protected header
# + jku - the `jku` (JWK Set URL) claim from the protected header, if the
#         signer included one
# + return - the public key to verify that signature entry with
public type AgentCardKeyProvider isolated function (string kid, string? jku) returns crypto:PublicKey|error;

# Raised when no signature on the card could be verified - either none
# verified against the key(s) the AgentCardKeyProvider supplied, no
# `signatures` were present at all, or a signature entry was structurally
# malformed (missing protected-header claims, an unsupported `alg`, a
# non-base64url field). Deliberately one error type for all of these:
# spec 8.4.3's procedure has no notion of a partially-valid signature, so
# a caller only ever needs to know "trusted" versus "not," not which of
# several ways verification failed for any one entry.
public type AgentCardSignatureError distinct error;

# Wraps any raw error (JSON shape mismatch, invalid UTF-8, malformed
# base64url, a crypto library failure, a key provider's own error) into
# this module's single public error type, so nothing but
# AgentCardSignatureError ever crosses verifyAgentCardSignature's or
# canonicalizeAgentCardBody's boundary - matching errors.bal's
# wrapTransportError, but for this module's own error type rather than
# Error, since signature verification is a distinct concern from
# transport/protocol handling and already had its own dedicated error
# type before this change.
#
# + e - the raw error to wrap
# + return - `e` unchanged if it is already an AgentCardSignatureError,
#            otherwise a new AgentCardSignatureError wrapping its message
isolated function wrapSignatureError(error e) returns AgentCardSignatureError {
    if e is AgentCardSignatureError {
        return e;
    }
    return error AgentCardSignatureError(string `signature verification failed: ${e.message()}`);
}

# Verifies at least one signature on a raw AgentCard JSON body, per
# specification section 8.4.3.
#
# ```ballerina
# json rawCard = check a2a:fetchAgentCardBody(url);
# check a2a:verifyAgentCardSignature(rawCard, keyProvider);
# a2a:AgentCard card = check a2a:parseAgentCardBody(rawCard);
# ```
#
# Must be called with the **raw** JSON body - see the file header comment
# for why a parsed `AgentCard` record cannot be substituted here.
#
# + rawCard - the raw JSON AgentCard body exactly as received (e.g. from
#             `fetchAgentCardBody`)
# + keyProvider - resolves the public key for a signature's `kid`/`jku`
# + return - `()` if at least one signature verified, or an
#            AgentCardSignatureError if none did
public isolated function verifyAgentCardSignature(json rawCard, AgentCardKeyProvider keyProvider) returns AgentCardSignatureError? {
    map<json>|error cardMapResult = rawCard.ensureType();
    if cardMapResult is error {
        return wrapSignatureError(cardMapResult);
    }
    map<json> cardMap = cardMapResult;
    json signaturesJson = cardMap["signatures"] ?: [];
    json[] signatures = signaturesJson is json[] ? signaturesJson : [];
    if signatures.length() == 0 {
        return error AgentCardSignatureError("no signatures found on AgentCard to verify");
    }

    string canonicalPayload = check canonicalizeAgentCardBody(rawCard);
    byte[] payloadBytes = canonicalPayload.toBytes();
    string encodedPayload = encodeBase64Url(payloadBytes);

    foreach json entry in signatures {
        AgentCardSignatureError? result = verifyOneSignatureEntry(entry, encodedPayload, payloadBytes, keyProvider);
        if result is () {
            return; // spec: verification succeeds if any one signature verifies
        }
        // Deliberately not surfaced per-entry - matches the reference
        // SDKs (a2a-js logs and continues; Python's try_all does the
        // same): one card commonly carries signatures from more than one
        // signer, so one malformed or non-matching entry is routine, not
        // exceptional. Only "none of them verified" is reported.
    }
    return error AgentCardSignatureError("no valid signature found among the AgentCard's signatures entries");
}

# Verifies a single `signatures[]` entry against the already-canonicalized
# payload.
#
# + entry - one raw `signatures[]` array element
# + encodedPayload - the base64url-encoded canonical payload (the JWS
#                     signing input's second segment)
# + payloadBytes - the same payload, undecoded, for algorithms whose
#                   ballerina/crypto verify function wants raw bytes
# + keyProvider - resolves the public key for this entry's `kid`/`jku`
# + return - `()` if this entry verified, or an error if it didn't (never
#            propagated to the caller of verifyAgentCardSignature -
#            callers only see the aggregate result)
isolated function verifyOneSignatureEntry(
        json entry,
        string encodedPayload,
        byte[] payloadBytes,
        AgentCardKeyProvider keyProvider) returns AgentCardSignatureError? {
    map<json>|error entryMapResult = entry.ensureType();
    if entryMapResult is error {
        return wrapSignatureError(entryMapResult);
    }
    map<json> entryMap = entryMapResult;
    json? protectedJson = entryMap["protected"];
    json? signatureJson = entryMap["signature"];
    if protectedJson !is string || signatureJson !is string {
        return error AgentCardSignatureError("signature entry missing string 'protected' or 'signature' field");
    }

    byte[] protectedHeaderBytes = check decodeBase64Url(protectedJson);
    string|error protectedHeaderTextResult = string:fromBytes(protectedHeaderBytes);
    if protectedHeaderTextResult is error {
        return wrapSignatureError(protectedHeaderTextResult);
    }
    string protectedHeaderText = protectedHeaderTextResult;
    json|error protectedHeaderJsonResult = protectedHeaderText.fromJsonString();
    if protectedHeaderJsonResult is error {
        return wrapSignatureError(protectedHeaderJsonResult);
    }
    map<json>|error protectedHeaderResult = protectedHeaderJsonResult.ensureType();
    if protectedHeaderResult is error {
        return wrapSignatureError(protectedHeaderResult);
    }
    map<json> protectedHeader = protectedHeaderResult;

    // Per spec 8.4.2 the protected header MUST include alg and kid (typ
    // SHOULD be present but carries no information needed to verify, so
    // it is not required here).
    json? algJson = protectedHeader["alg"];
    json? kidJson = protectedHeader["kid"];
    if algJson !is string || kidJson !is string {
        return error AgentCardSignatureError("signature entry's protected header is missing 'alg' or 'kid'");
    }
    json? jkuJson = protectedHeader["jku"];
    string? jku = jkuJson is string ? jkuJson : ();

    crypto:PublicKey|error publicKeyResult = keyProvider(kidJson, jku);
    if publicKeyResult is error {
        return wrapSignatureError(publicKeyResult);
    }
    crypto:PublicKey publicKey = publicKeyResult;
    byte[] signatureBytes = check decodeBase64Url(signatureJson);

    // JWS signing input, per RFC 7515 - identical for every serialization
    // (compact or flattened JSON): BASE64URL(protected header) || "." ||
    // BASE64URL(payload). protectedJson is already the wire's own
    // base64url encoding, reused verbatim rather than re-encoded, so this
    // is byte-identical to what the signer actually signed even if their
    // encoder made different (spec-legal) padding/whitespace choices than
    // ours would have.
    string signingInput = string `${protectedJson}.${encodedPayload}`;
    byte[] signingInputBytes = signingInput.toBytes();

    if algJson == "RS256" {
        boolean|error valid = crypto:verifyRsaSha256Signature(signingInputBytes, signatureBytes, publicKey);
        if valid is error {
            return wrapSignatureError(valid);
        }
        return valid ? () : error AgentCardSignatureError("RS256 signature did not verify");
    }
    if algJson == "ES256" {
        byte[] derSignature = check ecdsaJwsSignatureToDer(signatureBytes);
        boolean|error valid = crypto:verifySha256withEcdsaSignature(signingInputBytes, derSignature, publicKey);
        if valid is error {
            return wrapSignatureError(valid);
        }
        return valid ? () : error AgentCardSignatureError("ES256 signature did not verify");
    }
    return error AgentCardSignatureError(string `unsupported signature algorithm "${algJson}" - only RS256 and ES256 are implemented`);
}

# Converts a JWS ES256 signature (RFC 7518 §3.4: the raw concatenation of
# two 32-byte big-endian unsigned integers, R then S) into the DER
# `ECDSA-Sig-Value` encoding `ballerina/crypto`'s
# `verifySha256withEcdsaSignature` actually expects - it delegates to
# Java's `Signature.getInstance("SHA256withECDSA")`, which is JCA-native
# DER, not the raw JOSE format. Skipping this conversion makes every real
# ES256 JWS signature fail to verify (or error outright), regardless of
# whether it is genuinely valid - confirmed empirically against a real
# a2a-js-generated signature while writing this module.
#
# + rawSignature - the 64-byte raw R‖S signature, as carried in a JWS
#                   `signature` field
# + return - the same signature, DER-encoded
isolated function ecdsaJwsSignatureToDer(byte[] rawSignature) returns byte[]|AgentCardSignatureError {
    if rawSignature.length() != 64 {
        return error AgentCardSignatureError(
                string `ES256 signature must be exactly 64 bytes (raw R‖S), found ${rawSignature.length()}`);
    }
    byte[] r = derInteger(rawSignature.slice(0, 32));
    byte[] s = derInteger(rawSignature.slice(32, 64));
    byte[] content = [...r, ...s];
    // Short-form DER length only (a single length byte, content < 128
    // bytes): each INTEGER is at most 2 (tag+length) + 33 (32 content
    // bytes plus, at most, one leading 0x00 sign-guard byte) = 35 bytes,
    // so content here is at most 70 bytes - always well under the
    // 128-byte threshold where DER's long-form length encoding would be
    // needed. True for every P-256 signature; this function is only ever
    // called for ES256, so that is the only case that needs to hold.
    return [0x30, <byte>content.length(), ...content];
}

# DER-encodes one unsigned big-endian integer (a P-256 signature's R or S
# component) as an ASN.1 INTEGER, per X.690: strip leading zero bytes
# (keeping at least one byte), then prepend a single 0x00 guard byte if
# the high bit of what remains is set - otherwise DER would read a value
# with its high bit set as negative, which R and S, as unsigned
# coordinates, never are.
#
# + value - the 32-byte unsigned big-endian integer
# + return - the DER `INTEGER` TLV (tag 0x02, length, content)
isolated function derInteger(byte[] value) returns byte[] {
    int firstNonZero = 0;
    while firstNonZero < value.length() - 1 && value[firstNonZero] == 0 {
        firstNonZero += 1;
    }
    byte[] trimmed = value.slice(firstNonZero);
    byte[] content = trimmed[0] >= 0x80 ? [0x00, ...trimmed] : trimmed;
    return [0x02, <byte>content.length(), ...content];
}

# Base64url-encodes a byte array (RFC 4648 §5): standard base64, with `+`
# and `/` swapped for `-` and `_`, and padding omitted - the alphabet
# every JWS segment (protected header, payload, signature) uses.
# `ballerina/lang.array` only provides standard base64 (`toBase64`), so
# this hand-rolls the substitution; there is no plain (non-regex)
# character-replace in `lang.string` either, so it goes character by
# character rather than reach for regex to replace two literal
# characters - the same tradeoff `buildRestRequest` (client.bal) already
# made for path-placeholder substitution.
#
# + data - the bytes to encode
# + return - the base64url encoding, unpadded
isolated function encodeBase64Url(byte[] data) returns string {
    string standard = data.toBase64();
    string[] pieces = [];
    foreach int i in 0 ..< standard.length() {
        string c = standard.substring(i, i + 1);
        if c == "+" {
            pieces.push("-");
        } else if c == "/" {
            pieces.push("_");
        } else if c != "=" {
            pieces.push(c);
        }
    }
    return string:'join("", ...pieces);
}

# Reverses `encodeBase64Url`: swaps the alphabet back and restores the
# `=` padding standard base64 decoding requires.
#
# + encoded - the base64url string to decode (unpadded, per RFC 4648 §5)
# + return - the decoded bytes, or an error if `encoded` isn't valid
#            base64url
isolated function decodeBase64Url(string encoded) returns byte[]|AgentCardSignatureError {
    string[] pieces = [];
    foreach int i in 0 ..< encoded.length() {
        string c = encoded.substring(i, i + 1);
        if c == "-" {
            pieces.push("+");
        } else if c == "_" {
            pieces.push("/");
        } else {
            pieces.push(c);
        }
    }
    string standard = string:'join("", ...pieces);
    int remainder = standard.length() % 4;
    if remainder == 2 {
        standard = standard + "==";
    } else if remainder == 3 {
        standard = standard + "=";
    } else if remainder == 1 {
        return error AgentCardSignatureError("invalid base64url string length");
    }
    byte[]|error decoded = array:fromBase64(standard);
    if decoded is error {
        return wrapSignatureError(decoded);
    }
    return decoded;
}

# The v1.0 `AgentCard` proto message's complete field list (a2a.proto,
# `message AgentCard`), camelCased to match this library's (and the
# wire's) JSON field names. Nothing else survives into the canonical
# payload - see canonicalizeAgentCardBody's doc comment for why.
final readonly & string[] AGENT_CARD_V1_FIELDS = [
    "name", "description", "supportedInterfaces", "provider", "version",
    "documentationUrl", "capabilities", "securitySchemes", "securityRequirements",
    "defaultInputModes", "defaultOutputModes", "skills", "signatures", "iconUrl"
];

# Canonicalizes a raw AgentCard JSON body for signing or verification, per
# specification section 8.4.1: keeps only the fields the v1.0 `AgentCard`
# proto message actually defines, strips every proto3-default-valued
# property among those, then serializes with RFC 8785 JSON Canonicalization
# (JCS) - object keys sorted, no insignificant whitespace.
#
# Exposed publicly, matching both reference SDKs (`canonicalizeAgentCard`
# in a2a-js, the equivalent in Python's `a2a-sdk`): a caller doing their
# own signing tooling, or debugging why a signature doesn't verify, needs
# to be able to reproduce exactly what gets signed.
#
# **The schema-filtering step matters more than it first looks.** Spec
# 8.4.1 says canonicalization must respect "Protocol Buffer field
# presence semantics" - i.e. operate on the *proto* shape, not whatever
# JSON happened to arrive on the wire. A real v1.0 card can legitimately
# carry the legacy top-level `url` field too (for older v0.3 clients'
# benefit; this library's own `primaryUrl` reads it as a fallback), but
# `url` is not a field of the v1.0 `AgentCard` proto message at all - so
# a spec-conformant signer's own proto round-trip drops it before
# signing, and a verifier that doesn't drop it the same way computes a
# different payload and never verifies a legitimately-signed card.
# Confirmed the hard way: an earlier version of this function canonicalized
# the raw map directly (no schema filter) and failed to reproduce a real
# a2a-js-signed fixture's canonical payload byte-for-byte, off by exactly
# the retained `url` field - see the design plan and signature_test.bal's
# comment for how that fixture was produced and cross-checked.
#
# Applied at the **top level only**, not recursively into nested messages
# (`AgentSkill`, `AgentInterface`, `SecurityScheme`, ...) - a bounded gap,
# not an oversight: modeling every nested message's own field list is
# real added complexity for a case this library's own AgentCard-producing
# code never creates (nested legacy/unknown fields would only appear from
# a third party's non-conformant card), whereas the top-level `url` case
# is something a real, otherwise-conformant v1.0 agent can and does
# legitimately publish.
#
# Two more known, deliberately bounded gaps against a byte-perfect RFC 8785
# implementation, both confirmed against the real reference implementation
# rather than assumed:
#
# - **Number formatting** is Ballerina's own `json` number-to-string
#   conversion, not a hand-rolled ECMAScript `Number::toString`
#   (RFC 8785 §3.2.2.3). `1.0` renders as `"1.0"` here where JCS/JS would
#   render `"1"`. AgentCard's schema carries no numeric fields at all
#   (pageSize/historyLength are the closest, both plain integers, which
#   render identically either way); a mismatch is only reachable through
#   an open/rest `json` field carrying a float, e.g.
#   `AgentExtension.params`. a2a-js's own `jcsStringify` has the identical
#   gap - it delegates every leaf value to native `JSON.stringify`, which
#   is exactly ECMAScript `Number::toString`, but is *not* attempting
#   RFC 8785's specific canonical-number-string algorithm either; the two
#   only coincide because ECMAScript's own JSON.stringify already matches
#   it for ordinary numbers.
# - **Default-value stripping** matches what the reference SDKs actually
#   do (confirmed by reading a2a-js's `cleanEmpty` directly), not a
#   literal proto3 field-presence check: a property is stripped when its
#   value is `""`, `null`, `[]`, or `{}` (after the same stripping is
#   applied recursively first). `false` and `0` are explicit values, kept
#   as-is - proto3's own zero-value story more literally, but not what
#   `cleanEmpty` implements, and matching the reference implementation's
#   actual behavior is what makes a real signature verify.
#
# + rawCard - the raw JSON AgentCard body (with or without a `signatures`
#             field, and with or without legacy fields like `url` - all
#             are excluded either way)
# + return - the canonical JSON string, or an error if rawCard is not a
#            JSON object
public isolated function canonicalizeAgentCardBody(json rawCard) returns string|AgentCardSignatureError {
    map<json>|error cardMapResult = rawCard.ensureType();
    if cardMapResult is error {
        return wrapSignatureError(cardMapResult);
    }
    map<json> cardMap = cardMapResult;
    map<json> schemaFiltered = {};
    foreach string fieldName in AGENT_CARD_V1_FIELDS {
        if fieldName == "signatures" {
            continue; // excluded unconditionally, spec 8.4.1
        }
        json? fieldValue = cardMap[fieldName];
        if fieldValue !is () {
            schemaFiltered[fieldName] = fieldValue;
        }
    }
    json? stripped = stripJcsDefaults(schemaFiltered);
    return stripped is () ? "{}" : jcsSerialize(stripped);
}

# Recursively strips proto3-default-shaped values in preparation for JCS
# canonicalization - `""`, `null`, and, after the same recursive stripping
# is applied to their contents, arrays and objects that end up empty.
# Matches a2a-js's `cleanEmpty` exactly (confirmed by reading its source):
# booleans and numbers, `false`/`0` included, are never stripped - only
# string/array/object emptiness is.
#
# + value - the value to strip, at any depth
# + return - the stripped value, or `()` to signal to the caller (an
#            enclosing array/object) that this value counts as empty and
#            should itself be omitted
isolated function stripJcsDefaults(json value) returns json {
    if value == "" || value is () {
        return ();
    }
    if value is json[] {
        json[] cleanedArray = [];
        foreach json element in value {
            json cleanedElement = stripJcsDefaults(element);
            if cleanedElement !is () {
                cleanedArray.push(cleanedElement);
            }
        }
        return cleanedArray.length() > 0 ? cleanedArray : ();
    }
    if value is map<json> {
        map<json> cleanedMap = {};
        foreach [string, json] [k, v] in value.entries() {
            json cleanedValue = stripJcsDefaults(v);
            if cleanedValue !is () {
                cleanedMap[k] = cleanedValue;
            }
        }
        return cleanedMap.length() > 0 ? cleanedMap : ();
    }
    return value;
}

# Serializes an already-stripped JSON value as RFC 8785 JCS: object keys
# sorted (Ballerina's default string ordering is by Unicode code point,
# matching JCS's UTF-16-code-unit ordering for every code point AgentCard
# field names actually use - all ASCII), arrays in their existing order,
# no whitespace anywhere, and leaf values delegated to toJsonString()
# (see the two bounded gaps documented on `canonicalizeAgentCardBody`).
#
# + value - the value to serialize, at any depth
# + return - the canonical JSON string for this value
isolated function jcsSerialize(json value) returns string {
    if value is map<json> {
        string[] sortedKeys = value.keys().sort();
        string[] parts = [];
        foreach string k in sortedKeys {
            parts.push(string `${k.toJsonString()}:${jcsSerialize(value.get(k))}`);
        }
        return string `{${string:'join(",", ...parts)}}`;
    }
    if value is json[] {
        string[] parts = [];
        foreach json element in value {
            parts.push(jcsSerialize(element));
        }
        return string `[${string:'join(",", ...parts)}]`;
    }
    return value.toJsonString();
}
