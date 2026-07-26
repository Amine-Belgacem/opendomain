# OpenDomain

OpenDomain is a PowerShell-based bulk domain availability checker that uses RDAP first and falls back to WHOIS when needed.

## Features

- Check multiple domains from a file, command-line input, or clipboard
- Use concurrent requests with configurable timeout and thread count
- Write results to a timestamped log file
- Works with the bundled Windows WHOIS executable when available

## Requirements

- Windows
- PowerShell 5.1 or later
- Optional: the bundled `whois.exe` file in this repository for WHOIS fallback

## Usage

Run the script directly:

```powershell
./opendomain.ps1 example.com
```

Or with a file of domains:

```powershell
./opendomain.ps1 -File domains.txt -Timeout 15 -Threads 10
```

Use `-Help` for more details.

## Notes

The script reads domains from:
- a file passed with `-File`
- a command-line argument
- clipboard contents when no input file is provided
