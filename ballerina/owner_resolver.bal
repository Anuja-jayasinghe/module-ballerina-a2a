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

// Server-side identity resolution, for task-visibility scoping. Mirrors
// auth.bal's CredentialProvider in shape -- a pluggable, single-method
// isolated object -- for the server's own equivalent need:
// [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping) requires that "clients can only access authorized tasks,"
// but the specification defines no mechanism for establishing who a caller
// is. That is deployment policy, not protocol, so this library surfaces a
// hook rather than inventing an authentication scheme.

import ballerina/http;

# Resolves the caller of an inbound request to an opaque owner scope, for
# task-visibility scoping.
#
# `()` is a legitimate scope, not "unscoped" or "trusted": every caller a
# configured resolver maps to `()` shares one pool, isolated from every
# other scope, same as any other value. Leaving `a2a:ListenerConfiguration`'s
# `ownerResolver` entirely unset is different from a resolver that always
# returns `()` only in that the former matches this server's behavior before
# this feature existed -- every task in one shared, unscoped pool.
#
# Implement this against whatever identifies a caller in your deployment — a
# bearer token's subject claim, an mTLS certificate's principal, an API key
# looked up against a directory. This resolves identity; it does not
# authenticate it. A resolver that trusts an unverified header is not a
# security boundary, and satisfying [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping) requires
# pairing this with real inbound authentication, which is deployment policy
# this library does not prescribe.
public type TaskOwnerResolver isolated object {

    # Resolves the request's caller to an owner scope.
    #
    # + req - The inbound HTTP request
    # + return - The caller's owner scope, `()` if the request carries no
    #            resolvable identity, or an error if resolution itself failed
    #            (a malformed token, an unreachable directory) — distinct
    #            from a legitimately anonymous `()` result
    public isolated function resolveOwner(http:Request req) returns string?|Error;
};
