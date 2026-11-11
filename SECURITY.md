# Security policy

This is an early preview. Only the latest release and the latest commit on
`main` get security fixes. There is no security support SLA.

Report vulnerabilities privately to
[hello@morrowdock.app](mailto:hello@morrowdock.app), the security contact for
this project, or use GitHub's private vulnerability reporting: **Security** tab,
then **Report a vulnerability**.

Include the affected commit or release, the impact, minimal synthetic steps to
reproduce and how we can reply to you. Do not put vulnerabilities, secrets,
personal data or private course material in public issues. We coordinate
disclosure after a fix is available. Never include credentials in a report.

Bugs in the engine itself (a document that crashes the parser or passes a check
it must fail) go to
[MartyGraphics](https://github.com/morrowdock/martygraphics/blob/main/SECURITY.md).

## Design rules that limit risk

- The MCP server reads requests only from standard input. It opens no network
  connection and runs no shell command.
- Model output is data. Marty never runs model text as code or as a command.
- Every input has a size limit. Documents larger than the engine format limit
  are refused before they are parsed.
- The server writes files only into its own output directory.
