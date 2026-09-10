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

// v1.0 SecurityScheme wire-form parsing helpers, split out of
// types.bal (which should hold type definitions, not functions).

# Every JSON key that can introduce a v1.0 `SecurityScheme` oneof arm.
#
# A2A v1.0 models SecurityScheme as a protobuf `oneof` (see `proto/a2a.proto`),
# so the wire form is a single wrapper key — `{"apiKeySecurityScheme": {...}}` —
# not the v0.3/OpenAPI `type` discriminator this module's SecurityScheme union
# is shaped around. The spec's own JSON schema for SecurityScheme accepts each
# arm under two spellings: a lowerCamelCase one (its `properties`) and a
# snake_case one (its `patternProperties`), so both are recognized here.
final readonly & string[] V10_SECURITY_SCHEME_ARM_KEYS = [
    "apiKeySecurityScheme",
    "api_key_security_scheme",
    "httpAuthSecurityScheme",
    "http_auth_security_scheme",
    "oauth2SecurityScheme",
    "oauth2_security_scheme",
    "openIdConnectSecurityScheme",
    "open_id_connect_security_scheme",
    "mtlsSecurityScheme",
    "mtls_security_scheme"
];

# Whether a raw securitySchemes entry is in the v1.0 oneof-wrapper form.
#
# Checked separately from unwrapping so that an entry which *declares* an arm
# but carries a malformed payload is dropped outright rather than falling
# through to the v0.3 clone below — where `MutualTlsSecurityScheme` (no
# required fields, defaulted `type`) would match it and silently mislabel it.
#
# + entry - the raw securitySchemes entry
# + return - true if any of the ten recognized wrapper keys is present
isolated function hasV10SecuritySchemeArm(map<json> entry) returns boolean {
    foreach string armKey in V10_SECURITY_SCHEME_ARM_KEYS {
        if entry.hasKey(armKey) {
            return true;
        }
    }
    return false;
}

# Returns one v1.0 oneof arm's payload as a mutable copy, looked up under
# either spelling the spec accepts for it.
#
# + entry - the raw securitySchemes entry
# + camelKey - the lowerCamelCase spelling, per the spec schema's `properties`
# + snakeKey - the snake_case spelling, per its `patternProperties`
# + return - the arm's payload, or () if this entry declares no such arm (or
#            declares it as something other than an object)
isolated function v10SecuritySchemeArm(map<json> entry, string camelKey, string snakeKey) returns map<json>? {
    json? value = entry[camelKey];
    if value is () {
        value = entry[snakeKey];
    }
    return value is map<json> ? value.clone() : ();
}

# Renames one field of a raw JSON object in place, where the v1.0 wire name
# differs from this module's record field name. A no-op when the source field
# is absent, and never overwrites an existing target field.
#
# + fields - the object to rewrite
# + wireName - the field name as it arrives on the wire
# + recordName - the field name this module's record declares
isolated function renameJsonField(map<json> fields, string wireName, string recordName) {
    if fields.hasKey(wireName) && !fields.hasKey(recordName) {
        fields[recordName] = fields.remove(wireName);
    }
}

# Converts one v1.0 oneof-wrapped securitySchemes entry into the equivalent
# typed SecurityScheme.
#
# Mirrors `decodeGrpcSecurityScheme` (grpc_binding.bal), which already performs
# this same arm-by-arm mapping for the gRPC binding — the two paths must agree
# on which arm means what, and on rejecting an out-of-range apiKey location.
#
# Only two kinds of field-name fixup are needed. `location` becomes `in`
# (a genuine rename between the v1.0 and OpenAPI spellings), and the three
# multi-word fields the spec also accepts in snake_case are normalized to their
# camelCase form. Every other field name already matches, since protobuf JSON
# emits lowerCamelCase.
#
# The apiKey `location` value is compared case-insensitively. The proto
# documents it as lowercase "query"/"header"/"cookie", but a server generating
# it from a protobuf enum can emit other casing, and the reference Python SDK
# likewise lowercases before comparing (`AuthInterceptor`).
#
# KNOWN LIMITATION: nested OAuth *flow* objects are not snake_case-normalized —
# only the scheme-level fields are. A v1.0 card sending
# `{"authorization_code": ...}` inside `flows` parses without error but leaves
# that flow in `OAuthFlows`' open rest field rather than its typed
# `authorizationCode` field. This library does not act on OAuth2 flows
# itself — auth is caller-configured (see auth.bal) — so this costs typing
# detail, not function.
#
# + entry - a raw securitySchemes entry already known to declare an arm
# + return - the typed SecurityScheme, or () if the arm's payload doesn't
#            match the shape that arm requires (the caller drops it)
isolated function unwrapV10SecurityScheme(map<json> entry) returns SecurityScheme? {
    map<json>? apiKey = v10SecuritySchemeArm(entry, "apiKeySecurityScheme", "api_key_security_scheme");
    if apiKey is map<json> {
        json? location = apiKey["location"];
        if location !is string {
            return ();
        }
        string normalized = location.toLowerAscii();
        if normalized != "query" && normalized != "header" && normalized != "cookie" {
            return ();
        }
        _ = apiKey.remove("location");
        apiKey["in"] = normalized;
        ApiKeySecurityScheme|error scheme = apiKey.cloneWithType(ApiKeySecurityScheme);
        return scheme is ApiKeySecurityScheme ? scheme : ();
    }

    map<json>? httpAuth = v10SecuritySchemeArm(entry, "httpAuthSecurityScheme", "http_auth_security_scheme");
    if httpAuth is map<json> {
        renameJsonField(httpAuth, "bearer_format", "bearerFormat");
        HttpAuthSecurityScheme|error scheme = httpAuth.cloneWithType(HttpAuthSecurityScheme);
        return scheme is HttpAuthSecurityScheme ? scheme : ();
    }

    map<json>? oauth2 = v10SecuritySchemeArm(entry, "oauth2SecurityScheme", "oauth2_security_scheme");
    if oauth2 is map<json> {
        renameJsonField(oauth2, "oauth2_metadata_url", "oauth2MetadataUrl");
        OAuth2SecurityScheme|error scheme = oauth2.cloneWithType(OAuth2SecurityScheme);
        return scheme is OAuth2SecurityScheme ? scheme : ();
    }

    map<json>? oidc = v10SecuritySchemeArm(entry, "openIdConnectSecurityScheme", "open_id_connect_security_scheme");
    if oidc is map<json> {
        renameJsonField(oidc, "open_id_connect_url", "openIdConnectUrl");
        OpenIdConnectSecurityScheme|error scheme = oidc.cloneWithType(OpenIdConnectSecurityScheme);
        return scheme is OpenIdConnectSecurityScheme ? scheme : ();
    }

    map<json>? mtls = v10SecuritySchemeArm(entry, "mtlsSecurityScheme", "mtls_security_scheme");
    if mtls is map<json> {
        MutualTlsSecurityScheme|error scheme = mtls.cloneWithType(MutualTlsSecurityScheme);
        return scheme is MutualTlsSecurityScheme ? scheme : ();
    }

    return ();
}

# Parses each entry of a raw securitySchemes JSON object independently,
# silently omitting entries that don't match any known SecurityScheme
# variant (unrecognized `type`, or otherwise malformed) rather than
# failing the whole AgentCard parse. This keeps AgentCard parsing
# forward-compatible with scheme kinds a server might add in the future.
#
# Handles both wire dialects. A v1.0 card wraps each scheme in one of the
# five oneof arm keys (see `unwrapV10SecurityScheme`); a v0.3 card
# discriminates on a `type` field, which clones into the SecurityScheme union
# directly. The two forms are distinguished up front rather than by trying the
# union first: `MutualTlsSecurityScheme` requires no fields and defaults its
# `type`, so it matches *any* object without a `type` key — which is exactly
# what a v1.0 wrapper is, and why every v1.0 scheme used to be silently
# mislabelled as mutual TLS.
#
# + raw - the raw JSON value of the AgentCard's `securitySchemes` field
# + return - a map containing only the entries that parsed successfully
isolated function parseSecuritySchemes(json raw) returns map<SecurityScheme>|error {
    map<json> rawMap = check raw.ensureType();
    map<SecurityScheme> result = {};
    foreach [string, json] [name, schemeJson] in rawMap.entries() {
        if schemeJson is map<json> && hasV10SecuritySchemeArm(schemeJson) {
            SecurityScheme? unwrapped = unwrapV10SecurityScheme(schemeJson);
            if unwrapped is SecurityScheme {
                result[name] = unwrapped;
            }
            // A declared-but-malformed arm is dropped here, never retried
            // against the union below — see hasV10SecuritySchemeArm.
            continue;
        }
        SecurityScheme|error scheme = schemeJson.cloneWithType(SecurityScheme);
        if scheme is SecurityScheme {
            result[name] = scheme;
        }
    }
    return result;
}

# Unwraps one v1.0 `{"schemes": {...}}` security requirement.
#
# A2A v1.0 models SecurityRequirement as a protobuf message with a single
# `schemes` map field, and each of that map's values is a `StringList`
# message rather than a bare array — so a real v1.0 agent serves
# `{"schemes": {"bearer-staff": {"list": ["write"]}}}`, and `{}` for an
# empty scope list, where v0.3/OpenAPI served `{"bearer-staff": ["write"]}`.
# This module's SecurityRequirement type is the flat v0.3-shaped
# `map<string[]>`, so the v1.0 form has to be flattened onto it.
#
# + entry - one raw securityRequirements array element, already known to
#           be an object carrying an object-valued `schemes` key
# + return - the flattened requirement, or () if any scheme's value isn't
#            a StringList-shaped object
isolated function unwrapV10SecurityRequirement(map<json> entry) returns SecurityRequirement? {
    map<json>|error schemes = entry["schemes"].ensureType();
    if schemes is error {
        return ();
    }
    SecurityRequirement flattened = {};
    foreach [string, json] [schemeName, scopesJson] in schemes.entries() {
        map<json>|error stringList = scopesJson.ensureType();
        if stringList is error {
            return ();
        }
        json? listJson = stringList["list"];
        if listJson is () {
            // An empty StringList serialises as `{}` — no scopes, which is
            // the common case for a bearer or API-key scheme.
            flattened[schemeName] = [];
            continue;
        }
        string[]|error scopes = listJson.cloneWithType();
        if scopes is error {
            return ();
        }
        flattened[schemeName] = scopes;
    }
    return flattened;
}

# Whether a raw securityRequirements entry is in the v1.0 wrapper form.
#
# The discriminator is deliberately narrow: a v0.3 requirement could in
# principle name a scheme "schemes", but its value would then be a scope
# *array*, never an object. Only an object-valued `schemes` key means v1.0.
#
# + entry - one raw securityRequirements array element
# + return - true if this entry is the v1.0 wrapper form
isolated function hasV10SecurityRequirementWrapper(map<json> entry) returns boolean {
    return entry["schemes"] is map<json>;
}

# Parses a raw JSON array into a list of SecurityRequirement values,
# silently dropping any entry that matches neither wire form, so one
# malformed entry can't fail the whole AgentCard parse. Used for both
# AgentCard.securityRequirements and each AgentSkill's
# securityRequirements.
#
# Handles both dialects, mirroring parseSecuritySchemes above: v1.0 wraps
# the map in a `schemes` field and encodes scope lists as StringList
# objects (see unwrapV10SecurityRequirement); v0.3 uses the flat
# OpenAPI-style map this module's type is shaped around, which clones
# directly.
#
# + raw - the raw JSON value of a securityRequirements field
# + return - a list containing only the entries that parsed successfully
isolated function parseSecurityRequirements(json raw) returns SecurityRequirement[]|error {
    json[] rawArray = check raw.ensureType();
    SecurityRequirement[] result = [];
    foreach json entry in rawArray {
        if entry is map<json> && hasV10SecurityRequirementWrapper(entry) {
            SecurityRequirement? unwrapped = unwrapV10SecurityRequirement(entry);
            if unwrapped is SecurityRequirement {
                result.push(unwrapped);
            }
            // A declared-but-malformed wrapper is dropped here, never
            // retried against the flat form below — the same rule
            // parseSecuritySchemes applies to a malformed oneof arm.
            continue;
        }
        SecurityRequirement|error req = entry.cloneWithType(SecurityRequirement);
        if req is SecurityRequirement {
            result.push(req);
        }
    }
    return result;
}

# Parses a raw JSON array into a list of AgentCardSignature values,
# silently dropping any entry that doesn't match the AgentCardSignature
# shape, rather than failing the whole AgentCard parse over one
# malformed signature.
#
# + raw - the raw JSON value of the AgentCard's `signatures` field
# + return - a list containing only the entries that parsed successfully
isolated function parseAgentCardSignatures(json raw) returns AgentCardSignature[]|error {
    json[] rawArray = check raw.ensureType();
    AgentCardSignature[] result = [];
    foreach json entry in rawArray {
        AgentCardSignature|error sig = entry.cloneWithType(AgentCardSignature);
        if sig is AgentCardSignature {
            result.push(sig);
        }
    }
    return result;
}
