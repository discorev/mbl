# Codex app-server protocol notes

Validated on 2026-09-03 with `codex-cli 0.152.1`. The stdio transport is newline-delimited JSON. These messages deliberately omit a `jsonrpc` member, as shown in the protocol README and accepted by the installed server.

## Handshake

Send one request:

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"voice","version":"0.1"},"capabilities":{"experimentalApi":true}}}
```

The experimental capability is required because `dynamicTools` is currently experimental. The response shape received was:

```json
{"id":1,"result":{"userAgent":"voice/0.152.1 (Mac OS 26.7.0; arm64) ghostty/1.3.1 (voice; 0.1)","codexHome":"~/.codex","platformFamily":"unix","platformOs":"macos"}}
```

After that response, send this notification with no `id`:

```json
{"method":"initialized","params":{}}
```

## Start an isolated thread

The exact request used was:

```json
{"method":"thread/start","id":2,"params":{"model":"gpt-5.6-luna","cwd":"~/Developer/voice","approvalPolicy":"never","sandbox":"read-only","developerInstructions":"Clean the supplied dictation and output only the cleaned text. Do not use tools.","ephemeral":true,"dynamicTools":[]}}
```

Relevant response fields received:

```json
{"id":2,"result":{"thread":{"id":"01a0646a-1d33-7240-8f8d-864ad0dfedd3","ephemeral":true,"status":{"type":"idle"},"path":null,"cwd":"~/Developer/voice"},"model":"gpt-5.6-luna","modelProvider":"openai","cwd":"~/Developer/voice","approvalPolicy":"never","sandbox":{"type":"readOnly","networkAccess":false}}}
```

This confirms that `gpt-5.6-luna` was accepted. The full response contains additional fields, so the Swift decoder should either model them as optional or ignore unknown keys.

`approvalPolicy: "never"` prevents approval prompts, `sandbox: "read-only"` prevents writes and network access in the returned policy, and `dynamicTools: []` registers no client-supplied tools. There is no thread or turn field that removes Codex's built-in tools or user-configured MCP servers. The no-tool developer instruction is therefore also required; the check run made no tool calls. User-configured MCP servers may still emit startup notifications.

## Start a turn

Read `result.thread.id` from `thread/start`, then send:

```json
{"method":"turn/start","id":3,"params":{"threadId":"01a0646a-1d33-7240-8f8d-864ad0dfedd3","input":[{"type":"text","text":"um so the the test er passed I think"}],"effort":"none"}}
```

Luna rejected `"effort":"minimal"` with `unsupported_value`; its accepted values were reported as `none`, `low`, `medium`, `high`, `xhigh`, and `max`. The successful check therefore used `none`, which is the closest supported setting to the plan's minimal effort.

The immediate response shape was:

```json
{"id":3,"result":{"turn":{"id":"01a0646a-1e1d-76e1-a5bc-89fe9f0874f9","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
```

The server then streamed one or more deltas:

```json
{"method":"item/agentMessage/delta","params":{"threadId":"01a0646a-1d33-7240-8f8d-864ad0dfedd3","turnId":"01a0646a-1e1d-76e1-a5bc-89fe9f0874f9","itemId":"msg_0755ffbff58a7717016a98aea2aa4487d297b33318ac46bdf8","delta":"The"},"emittedAtMs":1788391074638}
```

The complete cleaned response arrived as an `item/completed` notification:

```json
{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_0755ffbff58a7717016a98aea2aa4487d297b33318ac46bdf8","text":"The test passed, I think.","phase":"final_answer","memoryCitation":null,"delivery":null},"threadId":"01a0646a-1d33-7240-8f8d-864ad0dfedd3","turnId":"01a0646a-1e1d-76e1-a5bc-89fe9f0874f9","completedAtMs":1788391075043},"emittedAtMs":1788391075043}
```

Do not consider the request finished until this notification arrives:

```json
{"method":"turn/completed","params":{"threadId":"01a0646a-1d33-7240-8f8d-864ad0dfedd3","turn":{"id":"01a0646a-1e1d-76e1-a5bc-89fe9f0874f9","items":[{"type":"agentMessage","id":"msg_0755ffbff58a7717016a98aea2aa4487d297b33318ac46bdf8","text":"The test passed, I think.","phase":"final_answer","memoryCitation":null,"delivery":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1788391071,"completedAt":1788391075,"durationMs":3807}},"emittedAtMs":1788391075079}
```

The runnable source of truth is `scripts/appserver-check.sh`. It prints every JSON line received and exits only after a completed turn containing an agent message.
