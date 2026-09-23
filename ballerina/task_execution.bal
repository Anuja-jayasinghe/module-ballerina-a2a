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

// The machinery behind live task streaming: a task driven detached from
// the request that started it, a broadcaster fanning its events out to
// however many subscribers attach, and a registry so a later, separate
// request can find the task still being driven.
//
// All three types are module-private -- unlike TaskStore/PushNotificationSender/
// TaskOwnerResolver (each a single-method, genuinely deployment-specific
// policy), this is three coupled interfaces around an in-process blocking
// queue. A multi-instance deployment can't implement the same contract with
// a real broker anyway, so this isn't a seam worth shipping; a deployment
// that needs to follow a task across instances already can, via push
// notifications.
//
// Verified against real, empirically-run scratch packages this session,
// not just read: `start` on an isolated method genuinely detaches an HTTP
// request from the work it starts; a blocking, poll-based next delivers
// values live as a separate detached producer pushes them, not pre-computed;
// multiple taps on one broadcaster each receive the identical sequence.
// Two isolation rules surfaced by that spike, both applied throughout this
// file: a value transferred out of a `lock` block must be `.clone()`d, and
// so must a value passed into a nested isolated object's method call from
// inside a `lock` block, even a plain parameter.

import ballerina/lang.runtime;

# How often a tap's blocking `next` polls for a new event. Short enough
# that live delivery feels immediate, long enough that many idle
# subscribers cost negligible CPU.
const decimal EVENT_POLL_INTERVAL = 0.05;

# A single subscriber's queue of a task's events.
#
# `next` blocks (polling, since `ballerina/lang.runtime` has no condition
# variable or semaphore) until an event is pushed, the tap is closed and
# drained, or `idleTimeout` elapses with nothing happening -- the backstop
# for a client that disconnects without the HTTP layer surfacing it as a
# clean stream close.
isolated class EventTap {
    private StreamResponse[] queue = [];
    private boolean closed = false;
    // Set by `endWithError`, consumed by the first `next` call that reaches an
    // empty queue after -- matches `stream<T, E>`'s completion semantics,
    // where the generator's `next` yields the completion error exactly
    // once, after every already-queued value.
    private Error? pendingError = ();
    private final decimal idleTimeout;

    # + idleTimeout - Seconds of no events before `next` gives up and
    #                 ends the stream; `0` disables the timeout
    isolated function init(decimal idleTimeout = 0) {
        self.idleTimeout = idleTimeout;
    }

    # Queues an event for this subscriber.
    #
    # + event - The event to deliver
    isolated function push(StreamResponse event) {
        lock {
            self.queue.push(event.clone());
        }
    }

    # Queues an event at the *front* of the queue, ahead of anything
    # already pushed -- used to prepend a task's current snapshot after a
    # subscriber has already attached (see `TaskExecutionRegistry.subscribe`'s
    # doc comment for why attach must happen before the snapshot read).
    #
    # + event - The event to prepend
    isolated function prependSnapshot(StreamResponse event) {
        lock {
            self.queue = [event.clone(), ...self.queue];
        }
    }

    # No more events will ever be pushed; `next` drains what remains,
    # then ends. Called by the producer side (`EventBroadcaster`) -- see
    # `close` for the consumer-side equivalent a stream's own caller uses.
    isolated function signalDone() {
        lock {
            self.closed = true;
        }
    }

    # Ends the stream with an error completion instead of a clean close --
    # once the queue drains, `next` returns `err` exactly once instead of
    # `()`. Used when a task's driving turn itself failed in a way no
    # `TaskStatusUpdateEvent` already communicates (see
    # `DefaultHandler.finishDrivenTask`).
    #
    # + err - The error to complete the stream with
    isolated function endWithError(Error err) {
        lock {
            self.pendingError = err;
            self.closed = true;
        }
    }

    isolated function isClosed() returns boolean {
        lock {
            return self.closed;
        }
    }

    # + return - The next event, `()` once closed and drained (or idle past
    #            `idleTimeout`), or an error
    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        decimal waited = 0;
        while true {
            lock {
                if self.queue.length() > 0 {
                    StreamResponse v = self.queue.shift();
                    return {value: v.clone()};
                }
                Error? pending = self.pendingError;
                if pending is Error {
                    self.pendingError = ();
                    return pending;
                }
                if self.closed {
                    return ();
                }
            }
            if self.idleTimeout > 0d && waited >= self.idleTimeout {
                return ();
            }
            runtime:sleep(EVENT_POLL_INTERVAL);
            waited += EVENT_POLL_INTERVAL;
        }
    }

    # Consumer-side close: the stream's own caller is done reading (e.g.
    # the HTTP connection dropped) -- required so `EventTap` satisfies
    # `stream<T,E>`'s generator interface. Functionally identical to
    # `signalDone`; kept as a separate, `public` method because that
    # interface requires `close` specifically, and reusing the name would
    # blur which side (producer vs. consumer) is signalling.
    #
    # + return - Always `()`; there is nothing that can fail here
    public isolated function close() returns error? {
        lock {
            self.closed = true;
        }
    }
}

# Fans one task's events out to every subscriber currently following it.
#
# Per specification section 3.5.2: every active stream for a task receives
# the same events in the same order, and closing one stream must not
# affect another.
isolated class EventBroadcaster {
    private EventTap[] taps = [];
    private boolean closed = false;

    # Delivers an event to every currently-open tap, dropping any that have
    # since closed (a subscriber disconnecting) so a long task with many
    # transient subscribers doesn't accumulate dead queues.
    #
    # + event - The event to broadcast
    isolated function push(StreamResponse event) {
        lock {
            EventTap[] stillOpen = [];
            foreach EventTap tap in self.taps {
                if !tap.isClosed() {
                    tap.push(event.clone());
                    stillOpen.push(tap);
                }
            }
            self.taps = stillOpen;
        }
    }

    # No more events will ever be broadcast; closes every open tap.
    isolated function close() {
        lock {
            foreach EventTap tap in self.taps {
                tap.signalDone();
            }
            self.closed = true;
        }
    }

    # Ends every currently-open tap with an error completion instead of a
    # clean close -- see `EventTap.endWithError`.
    #
    # + err - The error to complete every tap with
    isolated function endWithError(Error err) {
        lock {
            foreach EventTap tap in self.taps {
                tap.endWithError(err);
            }
            self.closed = true;
        }
    }

    # Attaches a new subscriber.
    #
    # If the broadcaster has already closed -- a subscriber arriving just
    # as the task finishes -- the returned tap comes back pre-closed rather
    # than registered into a dead broadcaster, so its `next` ends cleanly
    # instead of polling forever.
    #
    # + idleTimeout - Forwarded to the new tap
    # + return - A tap that will receive every event broadcast from here on
    isolated function newTap(decimal idleTimeout = 0) returns EventTap {
        final EventTap tap = new (idleTimeout);
        lock {
            if self.closed {
                tap.signalDone();
                return tap;
            }
            self.taps.push(tap);
        }
        return tap;
    }
}

# Tracks which tasks are actively being driven, so a later, separate
# request can find and follow one still in progress.
#
# `acquire` and `subscribe` differ in one thing: `acquire` claims the
# exclusive right to drive a task (a second concurrent message to the same
# in-flight task must be rejected, not run a second `TaskUpdater` racing
# the first); `subscribe` only needs to find or create the broadcaster to
# attach a tap to, and never blocks a driver from claiming the task later
# (a subscriber may legitimately attach to a paused, not-yet-resumed task).
isolated class TaskExecutionRegistry {
    private map<EventBroadcaster> broadcasters = {};
    // Which task ids currently have a driver running. A task can have a
    // broadcaster (because a subscriber attached to a paused task) without
    // a driver, and a driver without any subscribers -- the two are
    // tracked separately for exactly that reason.
    private map<boolean> driving = {};

    # Claims the exclusive right to drive a task, creating its broadcaster
    # if this is the task's first message.
    #
    # + taskId - The task to drive
    # + return - The broadcaster to push events to, or `()` if another
    #            driver already holds this task
    isolated function acquire(string taskId) returns EventBroadcaster? {
        lock {
            if self.driving[taskId] == true {
                return ();
            }
            self.driving[taskId] = true;
            EventBroadcaster broadcaster = self.broadcasters[taskId] ?: new;
            self.broadcasters[taskId] = broadcaster;
            return broadcaster;
        }
    }

    # Finds or creates the broadcaster for a task, without claiming the
    # driver slot -- for `subscribeToTask` attaching to a task that may or
    # may not currently have an active driver.
    #
    # + taskId - The task to follow
    # + return - The broadcaster to attach a tap to
    isolated function subscribe(string taskId) returns EventBroadcaster {
        lock {
            EventBroadcaster broadcaster = self.broadcasters[taskId] ?: new;
            self.broadcasters[taskId] = broadcaster;
            return broadcaster;
        }
    }

    # Releases the driver slot a prior `acquire` claimed.
    #
    # + taskId - The task that finished this driving turn
    # + terminal - Whether the task reached a terminal state -- if so, the
    #              broadcaster itself is dropped from the registry too,
    #              same as `InMemoryTaskStore` never expiring a task
    #              either; a paused (non-terminal) task keeps its
    #              broadcaster, so a later message resuming it reaches
    #              whatever subscribers already attached
    isolated function release(string taskId, boolean terminal) {
        lock {
            _ = self.driving.removeIfHasKey(taskId);
            if terminal {
                _ = self.broadcasters.removeIfHasKey(taskId);
            }
        }
    }

    # Finds a task's broadcaster if one already exists, without creating
    # one -- for `cancelTask`, which has nothing useful to broadcast to a
    # task nobody has ever driven or subscribed to, and must not claim or
    # touch the driver slot: a driver may genuinely still be running (a
    # live `sendStreamingMessage` subscriber can learn a taskId, and race
    # a `cancelTask` against it, before `onMessage` returns), and
    # `release`-ing that slot early here would let a second, concurrent
    # `acquire` for the same task id succeed while the first driver is
    # still actually running -- exactly the two-`TaskUpdater`s-racing
    # situation the interlock exists to prevent. `InMemoryTaskStore`'s own
    # terminal-state guard is what actually stops a still-running
    # `onMessage`'s further writes once `cancelTask`'s own `store.put`
    # below lands; the driver's own eventual `finishDrivenTask` still
    # releases the slot once it returns, whatever it returns.
    #
    # + taskId - The task to look up
    # + return - The existing broadcaster, or `()` if none has been
    #            created yet
    isolated function peekBroadcaster(string taskId) returns EventBroadcaster? {
        lock {
            return self.broadcasters[taskId];
        }
    }
}
