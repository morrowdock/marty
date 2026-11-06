# Security policy

This is an early preview. Only the latest `main` branch gets security fixes.
There is no security support SLA or stable release yet.

Report vulnerabilities privately to **admin@morrowdock.app**. Include the
affected commit, the impact and minimal synthetic steps to reproduce. Do not
put vulnerabilities, secrets, personal data or private course material in
public issues. We coordinate disclosure after a fix is available. Never include
credentials in a report.

## Design rules that limit risk

- The MCP server reads requests only from standard input. It opens no network
  connection and runs no shell command.
- Model output is data. Marty never runs model text as code or as a command.
- Every input has a size limit. Documents larger than the engine format limit
  are refused before they are parsed.
- The server writes files only into its own output directory.
