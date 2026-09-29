# Public Contract Test Register

This register states the tested promises of Jido Signal V3. Each ID is stable.
The generated cases and fixed tests both provide evidence. A passed contract ID
is evidence for its stated cases, not proof of the complete API or all process
schedules. Fixed-test cases in the last column are not generated evidence.

| ID | Public promise | Generated cases and independent model | Further fixed-test evidence |
| --- | --- | --- | --- |
| SIG-001 | Constructors validate the envelope and use documented defaults. Custom definitions validate domain data. | Supplied/generated IDs, default custom source, absent/null/Boolean/JSON/text/binary data, domain count schema, forbidden core characters, valid and invalid RFC3339 forms. Separately built field maps. | Full constructor and definition option/schema matrices. |
| CTX-001 | Context is flat. Names are valid. Values are Boolean, binary, or signed 32-bit integers. Input names do not create atoms. | Name lengths 1/20/21, reserved/uppercase names, duplicate atom/string names, integer bounds, nil/collection rejection, put/get/delete, unknown names. Plain map expectations. | Complete accepted/rejected name and value matrices. |
| WIRE-001 | Map, JSON, and Erlang term forms preserve Signal meaning and flat context. | All generated data forms, explicit/automatic Base64, opaque context bytes in ETF, JSON rejection of opaque context, null extension omission, duplicate lists. Independent canonical map before conversion. | Custom Signal wire envelopes and legacy markers. |
| WIRE-002 | Invalid wire input and byte-limit violations return errors. Batch decode returns no partial result. | Missing core fields, unsupported version/legacy marker, conflicting data forms, bad Base64, invalid extension value/name/type, malformed JSON/ETF, compressed ETF, improper ETF batch, exact byte limits, unsupported format/options. Known-invalid changes and exact size checks. | UTF-8 key/value boundaries and further option/decoder errors. |
| ROUTE-001 | Runtime, helper, compiled, and Store matching agree on path meaning. | Exact, single/multi wildcard, zero/many globstar segments, separated globstars, literal star type segments, invalid paths. Independent recursive recognizer. | More grammar and wildcard matrices. |
| ROUTE-002 | Targets use specificity, complexity, priority, and registration order. Predicate faults are no match. | Priorities -100..100, ties, duplicate paths, proper/opaque improper/nested/empty targets, true/false/other/raise/throw/exit MFA predicates. Independent list score and target model. | Runtime function predicates and priority validation boundaries. |
| ROUTE-003 | Route changes preserve old values and registration order. Compiled declarations require static data. | Add/merge/remove, shared paths, repeated removal, improper collections, fixed compiled module and complete code cleanup. Independent indexed list model after each change. | Module paths and compile rejection/line diagnostics for process values and functions. |
| DISP-001 | Dispatch validates each target, preserves delivery/error order, and emits safe events before it propagates callback faults. | Success/error/raise/throw/exit, invalid mode/config, improper lists, raw/normalized results, invalid HTTP header. Callback order, ordered error model, event sequence. | Invalid schemas, adapters, and built-in option matrices. |
| DISP-002 | PID delivery uses local live processes and the selected async/sync contract. | Live/self/dead/remote targets, async receipt, held sync call, two receiver results, timeout validation including the ceiling. Explicit messages and monitors. | Named targets, live delivery at the maximum timeout, timeout/exit outcomes, message formats. |
| BUS-001 | Publication validates the whole batch, appends before delivery, and advances cursors only on acceptance. | Empty/multiple/invalid/improper batches, append faults, duplicate Signals, append gate. Accepted-record log, cursor and callback snapshots. | Binary data and further schema/option cases. |
| BUS-002 | Ephemeral subscriptions deliver matches and remove routing/monitors on unsubscribe or target death. | Subscribe/unsubscribe, duplicate ID, matching publication, target death. Attached-state model and death barrier. | Nonmatching routes, shared paths, delete, local target validation, stale monitor messages. |
| BUS-003 | Replay uses an exclusive cursor and applies limits after filtering. | Cursor 0/current/beyond, limits 1/2/infinity, wildcard filters, empty log. Independent log filter and take. | Invalid options/paths and malformed Store results. |
| DUR-001 | One durable record is in flight. Its owner acknowledges it. Detach/death permits redelivery. | Wrong owner/cursor, no record, repeated detach, attach/death, filtered gaps, delete/recreate, live ownership conflict. Sequential state model and barriers. | Dead-owner replacement before DOWN handling and further start cursor cases. |
| DUR-002 | Durable definitions/cursors are stored before dependent changes. Store faults leave recoverable state. | Create/ack/delete/read faults, restart redelivery, exact restored timestamp spellings, malformed read data. Callback snapshots, stored cursor/definition checks. | Malformed startup definitions and cursors. |
| STORE-001 | Retention keeps unacknowledged required records. Capacity rejection is atomic and reports sorted blockers. | Bounds 1–5, overlapping subscriptions, matching/nonmatching records, cursor/delete release, invalid records/reads/updates. Independent retained list and required-record set. | Larger bursts and further Store option/record matrices. |
| STORE-002 | Callback faults and malformed data use defined error boundaries. The application owns external resources. | Each callback fault class, improper/non-map records, malformed reads, external Agent survival after Bus restart/stop. Fixed faults and snapshots. | Public startup failures and malformed startup callback values. |
| ERROR-001 | Error maps preserve type/retry policy, sanitize bounded details, and omit top-level stacktraces. | Six public constructors, grouped/improper errors, retry reasons, compound secret keys, long custom module names, Signal/URI/runtime/calendar values, depth/width/binary limits. Type/retry table and recursive output checks. | Unknown/grouped classes, normalization, Logger integration, more reason cases. |
| TRACE-001 | Trace carriers validate IDs/flags/state. Children retain the trace ID. | Root/child, zero/uppercase/invalid IDs, flags, duplicate/oversized state, put/get/delete/ensure, wire preservation. Independent carrier text. | Complete state grammar and option errors. |
| ID-001 | IDs are UUID7 values with readable timestamps and complete-value comparison. | Generated IDs, byte fixtures, version/variant/shape rejection, case forms, timestamp extremes, equality and tie order. Independent byte assembly/comparison. | Further invalid inputs and generation shape checks. |
| OBS-001 | Dispatch events pair each start with a terminal event. Bus events carry scoped identity and follow transitions. | Success/error/fault events; Bus publish/attach/deliver/ack/detach/delete/death/live-owner conflict; repeated detach. Ordered owned events and multiplicity checks. | Automatic dead-target replacement and Store delivery-error events. |

Case groups: envelope_wire, wire_mutations, routing_model, dispatch_sequences,
pid_lifecycles, bus_histories, durable_store_faults, memory_histories, diagnostics,
trace_ids, and bus_observations. Each has a short property test and a larger fuzz
test with the same assertions and saved inputs. See
[Property and Fuzz Tests](property-testing.md) for commands, bounds, and reports.

Generated histories are bounded and sequential. Messages test selected orders;
they do not control the BEAM scheduler. Fixed tests also own real HTTP, PubSub,
and Logger integration and broad compiler/schema diagnostics. No external
durable database, distributed delivery, retry policy, coverage-guided fuzz engine,
runtime matrix, or mutation score is claimed. Abrupt process death or timeout can
prevent shrinking or complete measurements, as stated in the testing guide.
