# Add the Marty MCP server to a client

`marty-mcp` speaks the Model Context Protocol over standard input and output
(the stdio transport). Any MCP client that can start a local command can use
it. It needs no network, API key or account.

## 1. Build

On macOS 14 or later with Swift 6:

```sh
git clone https://github.com/morrowdock/marty.git
cd marty
swift build -c release
BIN="$(swift build -c release --show-bin-path)/marty-mcp"
"$BIN" --version
```

Use the absolute path in `$BIN` in the client settings below.

## 2. Options

| Option | Effect |
| --- | --- |
| `--output-dir DIR` | `render` writes into new subdirectories of `DIR`. Default: `~/Library/Caches/marty-mcp/renders`. |
| `--no-render` | Turns `render` off. The other tools still work. |
| `--version` | Prints the server version and the engine commit, then stops. |

## 3. Claude Code

```sh
claude mcp add marty -- "$BIN" --output-dir "$HOME/marty-renders"
```

Then, in Claude Code, `/mcp` shows the server and its six tools.

## 4. Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and
restart Claude Desktop:

```json
{
  "mcpServers": {
    "marty": {
      "command": "/ABSOLUTE/PATH/TO/marty-mcp",
      "args": ["--output-dir", "/ABSOLUTE/PATH/TO/marty-renders"]
    }
  }
}
```

## 5. Other clients

Most clients take the same three values: a name (`marty`), a command (the
absolute path to `marty-mcp`) and arguments. The transport is `stdio`.

## 6. Try it

Ask the model: "Use the marty tools. Build a spur gear pair with 12 and 40
teeth, check it, and tell me the ratio the engine solved."

A good session calls `catalog`, writes a short document such as
`{"v": 1, "kind": "assembly", "title": "Spur pair", "units": "mm", "parts": [{"id": "g", "use": "spurPair", "with": {"wheelTeeth": 40}}]}`,
calls `check`, and reports the ratio from the result (−12/40 = −0.3).

## 7. Test the server by hand

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"shell","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"check","arguments":{"document":{"v":1,"kind":"assembly","title":"Pair","units":"mm","parts":[{"id":"g","use":"spurPair"}]}}}}' \
  | "$BIN" --no-render
```

Each answer is one line of JSON. Logs, when there are any, go to standard
error.

## Tools

See [DESIGN-MCP.md](DESIGN-MCP.md) for the rules and the full tool table.

| Tool | Use |
| --- | --- |
| `catalog` | Components, primitives, cameras and limits. Call it first. |
| `explain` | One component or primitive, with an example that the engine accepts. |
| `check` | The engine report, or the exact refusal reason and part. |
| `component_check` | Check a new component definition. |
| `patch` | Change a checked document (what-if) and check the result. |
| `render` | Stills, an optional loop GIF, a snapshot and a manifest. |
