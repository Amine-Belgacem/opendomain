# OpenDomain

Check multiple domain names from PowerShell using RDAP, with WHOIS fallback when needed.

## Get started

Requires Windows and PowerShell 5.1 or later. Keep the bundled `whois.exe` beside the script for WHOIS fallback.

```powershell
.\opendomain.ps1 example.com
```

To check domains from a file:

```powershell
.\opendomain.ps1 -File domains.txt -Timeout 15 -Threads 10
```

## Input and output

Domains can come from command-line input, a file, or the clipboard. Requests run concurrently with configurable timeouts, and results are written to a timestamped log in the script directory.

```powershell
.\opendomain.ps1 -Help
```

Results depend on the registry services responding; confirm a domain's current status with a registrar before acting on it.
