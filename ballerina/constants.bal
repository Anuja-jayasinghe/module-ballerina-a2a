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

// Wire constants shared across the HTTP+JSON transport, kept in one place so
// the header names and media types are never spelled out as bare literals at
// the call sites.

# The protocol-version header every A2A request carries (specification
# section 3.6.2).
const A2A_VERSION_HEADER = "A2A-Version";

# The A2A protocol version this library speaks.
const A2A_VERSION = "1.0";

# The content-type header name.
const CONTENT_TYPE_HEADER = "Content-Type";

# The A2A v1.0 JSON media type.
const CONTENT_TYPE_A2A_JSON = "application/a2a+json";

# The plain JSON media type, used for the v0.3 content-type fallback and for
# error bodies.
const CONTENT_TYPE_JSON = "application/json";

# The HTTP `Authorization` header, the destination for a resolved HTTP
# bearer or basic credential.
const AUTHORIZATION_HEADER = "Authorization";
