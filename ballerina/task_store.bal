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

// Where a server-side agent keeps the tasks it is running.
//
// A `Listener` running the task lifecycle for an `a2a:Service` needs
// somewhere to hold tasks between the request that creates one and the
// later requests that read or cancel it. That store is pluggable, matching
// both reference SDKs: `InMemoryTaskStore` is the default, and a production
// agent supplies its own backed by a database.

import ballerina/time;

# Whether a task state is terminal — no further transition is legal from it.
#
# The four terminal states are fixed by the specification (section 3.1.1):
# a message sent to a task in one of these must be refused.
#
# + state - The state to classify
# + return - Whether the state is terminal
public isolated function isTerminalState(TaskState state) returns boolean {
    return state == TASK_STATE_COMPLETED
        || state == TASK_STATE_FAILED
        || state == TASK_STATE_CANCELED
        || state == TASK_STATE_REJECTED;
}

# Persists and retrieves the tasks a server-side agent is running.
#
# Implement this to back a server's tasks with a real store — a database, a
# cache, a per-tenant partition. `a2a:InMemoryTaskStore` is provided for the
# simple case and for tests.
#
# Every method returns a narrowed `a2a:Error` on failure, so a storage fault
# surfaces the same way a protocol fault does rather than as a bare `error`.
public type TaskStore isolated object {

    # Stores a new task, or replaces an existing one with the same id.
    #
    # + task - The task to persist
    # + return - An error if the task could not be stored
    public isolated function put(Task task) returns Error?;

    # Retrieves a task by id.
    #
    # + id - The task's id
    # + return - The task, `()` if no task has this id, or an error if the
    #            lookup failed
    public isolated function get(string id) returns Task?|Error;

    # Lists tasks matching a filter, newest first, with cursor pagination.
    #
    # + filter - The filter and pagination parameters; every field is optional
    # + return - A page of matching tasks, or an error
    public isolated function list(ListTasksRequest filter) returns ListTasksResponse|Error;

    # Removes a task by id. A no-op when no task has the id.
    #
    # + id - The task's id
    # + return - An error if the removal failed
    public isolated function remove(string id) returns Error?;
};

# The default in-memory `a2a:TaskStore`.
#
# Holds tasks in a map guarded by a lock, enforces the specification's task
# state machine on every update, and orders `list` by status timestamp
# descending as section 3.1.4 requires. Tasks do not survive a restart — a
# production agent supplies its own `a2a:TaskStore` instead.
public isolated class InMemoryTaskStore {
    *TaskStore;

    private map<Task> tasks = {};
    # Insertion order, so `list` can page deterministically and the
    # newest-first sort has a stable tiebreak when timestamps match.
    private string[] insertionOrder = [];

    # Stores a new task, or replaces an existing one, enforcing the state
    # machine.
    #
    # A task already in a terminal state cannot be transitioned again: the
    # four terminal states are final per specification section 3.1.1, so an
    # attempt to move one is a caller error, not a silent overwrite.
    #
    # + task - The task to persist
    # + return - An `a2a:InternalError` if the task would illegally leave a
    #            terminal state, otherwise nil
    public isolated function put(Task task) returns Error? {
        lock {
            Task? existing = self.tasks[task.id];
            if existing is Task && isTerminalState(existing.status.state)
                    && existing.status.state != task.status.state {
                string msg = string `task ${task.id} is in terminal state `
                    + string `${existing.status.state} and cannot transition to ${task.status.state}`;
                return error InternalError(msg, message = msg);
            }
            if existing is () {
                self.insertionOrder.push(task.id);
            }
            self.tasks[task.id] = task.clone();
        }
    }

    # + id - The task's id
    # + return - The task, or `()` if none has this id
    public isolated function get(string id) returns Task?|Error {
        lock {
            Task? task = self.tasks[id];
            return task is Task ? task.clone() : ();
        }
    }

    # Lists tasks newest first, filtered and paged per specification section
    # 3.1.4.
    #
    # Tasks are sorted by `status.timestamp` descending; ties break on
    # insertion order. `contextId` and `status` filter the set;
    # `statusTimestampAfter` bounds it below. `pageToken` is the id of the
    # last task on the previous page. `nextPageToken` is always present and
    # empty when the page is the last. `artifacts` is omitted from every task
    # unless `includeArtifacts` is true, and `history` is trimmed to
    # `historyLength`.
    #
    # + filter - The filter and pagination parameters
    # + return - A page of matching tasks
    public isolated function list(ListTasksRequest filter) returns ListTasksResponse|Error {
        // Snapshot the store into a local, in insertion order, before
        // querying. A query capturing `self.tasks` directly trips the
        // compiler's isolation analysis inside a lock, and a mutable array
        // declared outside the lock cannot be pushed to from within it, so
        // the snapshot is built lock-local and cloned out.
        Task[] all;
        lock {
            Task[] snapshot = [];
            foreach string id in self.insertionOrder {
                Task? t = self.tasks[id];
                if t is Task {
                    snapshot.push(t.clone());
                }
            }
            all = snapshot.clone();
        }

        string? contextId = filter?.contextId;
        TaskState? status = filter?.status;
        string? after = filter?.statusTimestampAfter;
        Task[] matched = from Task t in all
            where contextId is () || t?.contextId == contextId
            where status is () || t.status.state == status
            where after is () || statusAtOrAfter(t, after)
            order by statusTimestampKey(t) descending
            select t;

        int pageSize = filter?.pageSize ?: matched.length();
        if pageSize < 0 {
            pageSize = 0;
        }
        int startIndex = 0;
        string? pageToken = filter?.pageToken;
        if pageToken is string {
            int? found = indexOfTaskId(matched, pageToken);
            startIndex = found is int ? found + 1 : matched.length();
        }
        int endIndex = startIndex + pageSize;
        if endIndex > matched.length() {
            endIndex = matched.length();
        }

        boolean includeArtifacts = filter?.includeArtifacts ?: false;
        int? historyLength = filter?.historyLength;
        Task[] page = [];
        foreach int i in startIndex ..< endIndex {
            page.push(projectTask(matched[i], includeArtifacts, historyLength));
        }

        string nextPageToken = endIndex < matched.length() && page.length() > 0
            ? page[page.length() - 1].id
            : "";
        return {
            tasks: page,
            nextPageToken,
            pageSize: page.length(),
            totalSize: matched.length()
        };
    }

    # + id - The task's id
    # + return - nil; removing a task that does not exist is a no-op
    public isolated function remove(string id) returns Error? {
        lock {
            _ = self.tasks.removeIfHasKey(id);
            int? idx = self.insertionOrder.indexOf(id);
            if idx is int {
                _ = self.insertionOrder.remove(idx);
            }
        }
    }
}

# Shapes a stored task for a `list` response: drops `artifacts` unless asked,
# and trims `history` to `historyLength`.
#
# Section 3.1.4 requires `artifacts` to be omitted entirely — not an empty
# array — when `includeArtifacts` is false, so this removes the field rather
# than blanking it.
#
# + task - The stored task
# + includeArtifacts - Whether to keep the artifacts field
# + historyLength - Maximum history messages to keep, or `()` for all
# + return - The projected copy
isolated function projectTask(Task task, boolean includeArtifacts, int? historyLength) returns Task {
    Task copy = task.clone();
    if !includeArtifacts {
        _ = copy.removeIfHasKey("artifacts");
    }
    if historyLength is int {
        Message[]? history = copy?.history;
        if history is Message[] && history.length() > historyLength {
            copy.history = historyLength <= 0 ? []
                : history.slice(history.length() - historyLength);
        }
    }
    return copy;
}

# Sort key for newest-first ordering: the status timestamp as epoch seconds,
# or 0 when a task carries no timestamp (it then sorts oldest, which is the
# safe default for an un-stamped task).
#
# + task - The task to key
# + return - Epoch seconds of the status timestamp, or 0
isolated function statusTimestampKey(Task task) returns decimal {
    string? ts = task.status?.timestamp;
    if ts is () {
        return 0;
    }
    time:Utc|error parsed = time:utcFromString(ts);
    return parsed is time:Utc ? <decimal>parsed[0] + parsed[1] : 0;
}

# Whether a task's status timestamp is at or after the given RFC 3339 bound.
#
# A task with no timestamp is treated as not matching a lower bound, since
# there is nothing to compare.
#
# + task - The task to test
# + after - The RFC 3339 lower bound
# + return - Whether the task's status timestamp is at or after `after`
isolated function statusAtOrAfter(Task task, string after) returns boolean {
    string? ts = task.status?.timestamp;
    if ts is () {
        return false;
    }
    time:Utc|error taskTs = time:utcFromString(ts);
    time:Utc|error bound = time:utcFromString(after);
    if taskTs is error || bound is error {
        return false;
    }
    return time:utcDiffSeconds(taskTs, bound) >= 0d;
}

# Index of the task with the given id in a list, or `()`.
#
# + tasks - The list to search
# + id - The id to find
# + return - The index, or `()` if not present
isolated function indexOfTaskId(Task[] tasks, string id) returns int? {
    foreach int i in 0 ..< tasks.length() {
        if tasks[i].id == id {
            return i;
        }
    }
    return;
}
