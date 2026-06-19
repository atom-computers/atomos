-- Cloud-Agnostic Web App Backend
-- Demonstrates: storage, pub/sub, task queues, rate limiting,
-- request routing, session management, and reactive dataflow
-- All using Gluon's region/process model — no threads, no locks, no event loops

-- ─── Data Regions ────────────────────────────────────────────────────

-- Request stream: incoming HTTP requests bucketed by time
region requests:  region[x: 4096req, y: 1, z: 1, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

-- Subscription registry: who listens to what channels
-- layout: [channel_hash: u32, subscriber_id: u32, created_ms: u32, flags: u8]
region subscriptions: region[x: 16384sub, y: 1, z: 1, t: 1] of U8x4
    @ LongTerm @ ReadWrite;

-- Pub/sub event channel: broadcast messages to subscribers
region events: region[x: 8192evt, y: 1, z: 1, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

-- Task queue: background work items (emails, analytics, webhooks)
region tasks: region[x: 2048task, y: 1, z: 1, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

-- Task results: completed task output
region task_results: region[x: 2048task, y: 1, z: 1, t: 1] of U8x4
    @ ShortTerm @ ReadWrite;

-- Persistent key-value store (object storage)
region kv_store: region[len: 8388608byte] of Raw
    @ LongTerm @ ReadWrite;

-- KV metadata: [key_hash: u32, offset: u32, value_len: u32, flags: u8]
region kv_index: region[x: 65536key, y: 1, z: 1, t: 1] of U8x4
    @ LongTerm @ ReadWrite;

-- Session tokens: [session_id: u32, user_id: u32, expires_ms: u32, role: u8]
region sessions: region[x: 8192session, y: 1, z: 1, t: 1] of U8x4
    @ LongTerm @ ReadWrite;

-- Rate limit counters: sliding window per client IP hash
region rate_counters: region[x: 4096client, y: 1, z: 1, t: 1] of F32x4
    @ ShortTerm @ ReadWrite;

-- Configuration: [max_req_per_sec: f32, max_sessions: f32, task_timeout_ms: f32, max_subs: f32]
region config: region[x: 1, y: 1, z: 1, t: 1] of F32x4
    @ LongTerm @ ReadOnly;

-- Response output: finished HTTP responses
region responses: region[x: 4096res, y: 1, z: 1, t: 2frames] of U8x4
    @ ShortTerm @ ReadWrite;

-- ─── Request Router ─────────────────────────────────────────────────

process router:
    reads  requests @ ReadOnly;
    reads  config @ ReadOnly;
    reads  sessions @ ReadOnly;
    reads  rate_counters;
    writes responses;
    private total_routed: u32 = 0;
    private error_count:   u32 = 0;

    when requests changes:
        -- Inspect the config for limits
        let max_rps      = config[x: 0, y: 0, z: 0, t: 0].c0;
        let max_sessions  = config[x: 0, y: 0, z: 0, t: 0].c1;

        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            if req_flag > 0.0:
                let client_hash = requests[x: slot, y: 0, z: 0, t: 0].c1;
                let path_hash   = requests[x: slot, y: 0, z: 0, t: 0].c2;
                let session_id  = requests[x: slot, y: 0, z: 0, t: 0].c3;

                -- Rate limit check
                let idx = client_hash as u32 % 4096;
                let current_rate = rate_counters[x: idx, y: 0, z: 0, t: 0].c0;
                if current_rate >= max_rps:
                    -- 429 Too Many Requests
                    responses[x: slot, y: 0, z: 0, t: 0] := [429, client_hash, 0, 0];
                else:
                    -- Validate session
                    let valid = validate_session(sessions, session_id, max_sessions);
                    if valid < 0.5:
                        -- 401 Unauthorized
                        responses[x: slot, y: 0, z: 0, t: 0] := [401, client_hash, path_hash, 0];
                    else:
                        -- Route to appropriate handler id encoded in path_hash
                        responses[x: slot, y: 0, z: 0, t: 0] := [200, client_hash, path_hash, session_id];
                        total_routed := total_routed + 1;
                    end
                end
            end
        end

    ensures:
        total_routed <= 4096;
        rate_counters[x: *, y: 0, z: 0, t: 0].c0 >= 0.0 forall elements;

    temporal invariant:
        always (rate_counters.c0 >= 0.0);
end

-- ─── Rate Limiter ────────────────────────────────────────────────────

process rate_limiter:
    reads  requests @ ReadOnly;
    reads  config @ ReadOnly;
    writes rate_counters;

    every 1s:
        -- Half-life decay: multiply all counters by 0.5 each second
        for each idx in 0..4096:
            let current = rate_counters[x: idx, y: 0, z: 0, t: 0].c0;
            rate_counters[x: idx, y: 0, z: 0, t: 0] := [current * 0.5, 0, 0, 0];
        end

    when requests changes:
        let max_rps = config[x: 0, y: 0, z: 0, t: 0].c0;
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            if req_flag > 0.0:
                let client_hash = requests[x: slot, y: 0, z: 0, t: 0].c1;
                let idx = client_hash as u32 % 4096;
                let current = rate_counters[x: idx, y: 0, z: 0, t: 0].c0;
                rate_counters[x: idx, y: 0, z: 0, t: 0] := [current + 1.0, 0, 0, 0];
            end
        end

    ensures:
        rate_counters[x: *, y: 0, z: 0, t: 0].c0 >= 0.0 forall elements;
end

-- ─── Key-Value Storage Engine ────────────────────────────────────────

process kv_writer:
    reads  requests @ ReadOnly;
    reads  config @ ReadOnly;
    writes kv_store;
    writes kv_index;
    private write_count: u32 = 0;

    when requests changes:
        let max_key_len = config[x: 0, y: 0, z: 0, t: 0].c2;
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes PUT operation (bit 31 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x80000000) != 0:
                let key_hash = path_hash as u32 & 0x7FFFFFFF;
                let idx = key_hash % 65536;

                -- Find value offset in kv_store (append-only for simplicity)
                let offset = write_count * 256;
                let existing_offset = kv_index[x: idx, y: 0, z: 0, t: 0].c0;

                if existing_offset == 0.0:
                    -- New key: store metadata
                    kv_index[x: idx, y: 0, z: 0, t: 0] := [offset as f32, 256.0, 1.0, 0];
                    write_count := write_count + 1;
                else:
                    -- Update existing: mark old as tombstoned, write new
                    kv_index[x: idx, y: 0, z: 0, t: 0] := [offset as f32, 256.0, 1.0, 0];
                    write_count := write_count + 1;
                end
            end
        end
end

process kv_reader:
    reads  requests @ ReadOnly;
    reads  kv_store @ ReadOnly;
    reads  kv_index @ ReadOnly;
    writes responses;

    when requests changes:
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes GET operation (bit 31 clear)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x80000000) == 0:
                let key_hash = path_hash as u32;
                let idx = key_hash % 65536;
                let offset = kv_index[x: idx, y: 0, z: 0, t: 0].c0 as u32;
                let val_len = kv_index[x: idx, y: 0, z: 0, t: 0].c1 as u32;

                if offset > 0 and val_len > 0 and val_len <= 256:
                    -- Found: return 200 + offset for downstream to read
                    responses[x: slot, y: 0, z: 0, t: 0] := [200, offset as f32, val_len as f32, 0];
                else:
                    -- Not found: 404
                    responses[x: slot, y: 0, z: 0, t: 0] := [404, 0, 0, 0];
                end
            end
        end
end

-- ─── Pub/Sub Engine ─────────────────────────────────────────────────

process pubsub_publish:
    reads  requests @ ReadOnly;
    reads  subscriptions @ ReadOnly;
    writes events;

    when requests changes:
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes PUBLISH (bit 30 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x40000000) != 0:
                let channel_hash = path_hash as u32 & 0x0FFFFFFF;

                -- Fan-out: find all subscribers to this channel
                let mut evt_idx = 0u32;
                for each sub in 0..16384:
                    let sub_channel = subscriptions[x: sub, y: 0, z: 0, t: 0].c0 as u32;
                    let sub_flags   = subscriptions[x: sub, y: 0, z: 0, t: 0].c3 as u32;

                    -- Check: active subscriber on matching channel
                    if sub_channel == channel_hash and (sub_flags & 1) != 0:
                        if evt_idx < 8192:
                            let subscriber_id = subscriptions[x: sub, y: 0, z: 0, t: 0].c1;
                            -- [channel_hash, subscriber_id, payload_slot, flags]
                            events[x: evt_idx, y: 0, z: 0, t: 0] := [channel_hash as f32, subscriber_id, slot as f32, 1.0];
                            evt_idx := evt_idx + 1;
                        end
                    end
                end

                -- Zero out any stale events beyond the ones we wrote
                for each i in evt_idx..8192:
                    events[x: i, y: 0, z: 0, t: 0] := [0, 0, 0, 0];
                end
            end
        end

    ensures:
        events[x: *, y: 0, z: 0, t: 0].c3 <= 1.0 forall elements;
end

process pubsub_subscribe:
    reads  requests @ ReadOnly;
    reads  config @ ReadOnly;
    writes subscriptions;

    when requests changes:
        let max_subs = config[x: 0, y: 0, z: 0, t: 0].c3 as u32;
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes SUBSCRIBE (bit 29 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x20000000) != 0:
                let channel_hash  = path_hash as u32 & 0x0FFFFFFF;
                let subscriber_id = requests[x: slot, y: 0, z: 0, t: 0].c1;
                let session_id    = requests[x: slot, y: 0, z: 0, t: 0].c3;
                let idx = (channel_hash ^ subscriber_id as u32) % 16384;

                -- Add subscription entry
                let created_ms = current_time_ms();
                subscriptions[x: idx, y: 0, z: 0, t: 0] := [channel_hash as f32, subscriber_id, created_ms, 1.0];
            end
        end

    ensures:
        subscriptions[x: *, y: 0, z: 0, t: 0].c3 <= 2.0 forall elements;
end

process pubsub_unsubscribe:
    reads  requests @ ReadOnly;
    writes subscriptions;

    when requests changes:
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes UNSUBSCRIBE (bits 29+30 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x60000000) == 0x60000000:
                let channel_hash  = path_hash as u32 & 0x0FFFFFFF;
                let subscriber_id = requests[x: slot, y: 0, z: 0, t: 0].c1;
                let idx = (channel_hash ^ subscriber_id as u32) % 16384;

                -- Tombstone: mark as inactive
                let existing = subscriptions[x: idx, y: 0, z: 0, t: 0];
                subscriptions[x: idx, y: 0, z: 0, t: 0] := [existing.c0, existing.c1, existing.c2, 0.0];
            end
        end
end

-- ─── Task Queue Worker ───────────────────────────────────────────────

process task_dispatcher:
    reads  requests @ ReadOnly;
    writes tasks;
    private next_slot: u32 = 0;

    when requests changes:
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes ASYNC_TASK (bit 28 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x10000000) != 0:
                let task_type = path_hash as u32 & 0x0FFFFFFF;
                let client_hash = requests[x: slot, y: 0, z: 0, t: 0].c1;
                let payload_slot = slot as f32;

                -- Enqueue task
                if next_slot < 2048:
                    tasks[x: next_slot, y: 0, z: 0, t: 0] := [task_type as f32, client_hash, payload_slot, 1.0];
                    next_slot := next_slot + 1;
                end
            end
        end
end

process task_worker:
    reads  tasks @ ReadOnly;
    reads  config @ ReadOnly;
    writes task_results;
    writes kv_store;
    private processed: u32 = 0;

    when tasks changes:
        let timeout_ms = config[x: 0, y: 0, z: 0, t: 0].c2;

        for each slot in 0..2048:
            let task_flag = tasks[x: slot, y: 0, z: 0, t: 0].c3;
            if task_flag > 0.0:
                let task_type    = tasks[x: slot, y: 0, z: 0, t: 0].c0 as u32;
                let client_hash  = tasks[x: slot, y: 0, z: 0, t: 0].c1;
                let payload_slot = tasks[x: slot, y: 0, z: 0, t: 0].c2;

                -- Route by task type
                -- 0x01: send_email, 0x02: push_notification,
                -- 0x03: webhook_callback, 0x04: analytics_event
                if task_type == 0x01:
                    -- Email: persist to storage for delivery
                    task_results[x: slot, y: 0, z: 0, t: 0] := [1, client_hash, payload_slot, 202];
                    processed := processed + 1;
                else if task_type == 0x02:
                    -- Push notification
                    task_results[x: slot, y: 0, z: 0, t: 0] := [2, client_hash, payload_slot, 202];
                    processed := processed + 1;
                else if task_type == 0x03:
                    -- Webhook callback
                    task_results[x: slot, y: 0, z: 0, t: 0] := [3, client_hash, payload_slot, 202];
                    processed := processed + 1;
                else if task_type == 0x04:
                    -- Analytics: aggregate into storage
                    task_results[x: slot, y: 0, z: 0, t: 0] := [4, client_hash, payload_slot, 202];
                    processed := processed + 1;
                else:
                    -- Unknown task type
                    task_results[x: slot, y: 0, z: 0, t: 0] := [task_type as f32, client_hash, 0, 400];
                end
            end
        end

    ensures:
        processed <= 4096;
end

-- ─── Session Manager ─────────────────────────────────────────────────

process session_manager:
    reads  requests @ ReadOnly;
    reads  config @ ReadOnly;
    writes sessions;
    private active_sessions: u32 = 0;

    when requests changes:
        let max_sessions = config[x: 0, y: 0, z: 0, t: 0].c1 as u32;
        for each slot in 0..4096:
            let req_flag = requests[x: slot, y: 0, z: 0, t: 0].c0;
            -- path_hash encodes AUTH operation (bit 27 set)
            let path_hash = requests[x: slot, y: 0, z: 0, t: 0].c2;
            if req_flag > 0.0 and (path_hash as u32 & 0x08000000) != 0:
                let auth_action  = path_hash as u32 & 0x07FFFFFF;
                let session_id   = requests[x: slot, y: 0, z: 0, t: 0].c3 as u32;
                let user_id      = requests[x: slot, y: 0, z: 0, t: 0].c1 as u32;
                let idx = session_id % 8192;

                if auth_action == 1:
                    -- Login: create session if under limit
                    if active_sessions < max_sessions:
                        let expires = current_time_ms() + 3600000;
                        sessions[x: idx, y: 0, z: 0, t: 0] := [session_id as f32, user_id as f32, expires as f32, 1.0];
                        active_sessions := active_sessions + 1;
                    end
                else if auth_action == 0:
                    -- Logout: tombstone the session
                    sessions[x: idx, y: 0, z: 0, t: 0] := [0, 0, 0, 0];
                    active_sessions := active_sessions - 1;
                else if auth_action == 2:
                    -- Refresh: extend expiry
                    let existing = sessions[x: idx, y: 0, z: 0, t: 0];
                    if existing.c3 > 0.0:
                        let new_expires = current_time_ms() + 3600000;
                        sessions[x: idx, y: 0, z: 0, t: 0] := [existing.c0, existing.c1, new_expires as f32, existing.c3];
                    end
                end
            end
        end

    ensures:
        active_sessions <= config[x: 0, y: 0, z: 0, t: 0].c1 as u32;
end

-- ─── Compaction & Maintenance ───────────────────────────────────────

process kv_compact:
    reads  kv_index @ ReadOnly;
    writes kv_store;

    every 60s:
        -- Garbage collect tombstoned entries
        -- In a real system this would be a merge-sort compaction
        let mut live_count = 0u32;
        for each idx in 0..65536:
            let flags = kv_index[x: idx, y: 0, z: 0, t: 0].c3 as u32;
            if flags != 0 and flags != 0xFF:
                live_count := live_count + 1;
            end
        end
        -- Mark compaction needed if >50% entries are dead
        -- Actual compaction handled by kv_writer on next write cycle
end

-- ─── Temporal Guarantees ────────────────────────────────────────────

temporal invariant:
    always (not (kv_store.being_written and kv_store.being_scanned));
    always (not (events.being_written and events.being_scanned));
    always (sessions.being_written ⇒ eventually sessions.being_scanned);
    always (rate_counters.c0 >= 0.0);
    always (tasks.being_written ⇒ eventually task_results.being_written);
    always (pubsub_publish.being_written ⇒ eventually events.being_written);