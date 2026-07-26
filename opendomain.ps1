<#
.SYNOPSIS
    Bulk domain availability checker using RDAP and WHOIS.

.DESCRIPTION
    This PowerShell script checks the availability of domain names using RDAP and falls back to 
    WHOIS if needed. It supports loading domains from a file, command line argument, or clipboard, 
    and can process multiple domains concurrently with configurable timeout and thread count.

.PARAMETER File
    Path to a file containing domains to check (one per line or in text).

.PARAMETER Timeout
    Timeout in seconds for each domain check (default: 20).

.PARAMETER Threads
    Maximum number of concurrent checks (default: 7).

.PARAMETER Help
    Show usage information and exit.

.NOTES
    - Requires PowerShell 5.1 or later.
    - whois.exe must be present in the script directory for WHOIS fallback.
    - Output is logged to a timestamped file in the script directory.
    - RDAP is used as primary lookup; WHOIS is used for unsupported TLDs or RDAP failures.

.EXAMPLE
    .\opendomain.ps1 -File domains.txt -Timeout 15 -Threads 10
    .\opendomain.ps1 example.com
    .\opendomain.ps1 -Help
#>

# PowerShell script for checking domain availability using RDAP and WHOIS

param(
    [Alias('f','File')][string]$InputFile = "",
    [Alias('t','Timeout')][int]$TimeoutSeconds = 20,
    [Alias('c','Threads')][int]$MaxThreads = 7,
    [Alias('h','?')][switch]$Help
)

# Show usage help and exit if -Help is specified
if ($Help) {
    @(
        "Usage: .\opendomain.ps1 [-File <file>] [-Timeout <seconds>] [-Threads <number>] [-Help]"
        ""
        "Arguments:"
        "  -File, -f        Path to a file containing domains"
        "  -Timeout, -t     Timeout in seconds for each domain check (default: 20)"
        "  -Threads, -c     Maximum number of concurrent checks (default: 7)"
        "  -Help, -h, -?    Show this help message and exit"
        ""
        "If no -File is provided, domains will be read from clipboard or command line argument."
    ) | Write-Host
    exit 0
}

# Centralized user-facing messages for maintainability
$UserMessages = @{
    NoDomainsLoaded         = "[ERROR] No domains loaded. Exiting."
    ClipboardError          = "[ERROR] Could not read clipboard. " +
                              "Please use a file or command line argument."
    NoDomainsClipboard      = "[ERROR] No domains found in the clipboard text."
    ClipboardHelp           = "You can also provide domains by loading a file " +
                              "or passing a command line argument."
    LoadedFromFile          = "Loaded {0} domains from file: {1}"
    LoadedFromArg           = "Loaded domains from command line argument."
    LoadedFromClipboard     = "Loaded {0} domains from clipboard."
    WhoisExeWarning         = "[WARNING] whois.exe not found in script directory. " +
                              "WHOIS will be unavailable for unsupported TLDs or RDAP failures."
    NoDomainSource          = "No source file provided. Reading chunk of text from clipboard..."
    TimeoutInfo             = "Timeout per domain: {0} seconds"
    MaxThreadsInfo          = "Max concurrent threads: {0}"
    LogFileInfo             = "Log file: {0}"
    CheckingDomains         = "Checking domains..."
    WhoisUnavailable        = "[ERROR] {0} (WHOIS unavailable)"
    WhoisTimeout            = "[ERROR] {0} (WHOIS lookup timed out after {1} seconds)"
    WhoisFallbackFailed     = "[ERROR] {0} (WHOIS fallback failed: {1})"
    DomainTakenRegistrar    = "[TAKEN] {0} (Registrar: {1})"
    DomainTakenNoRegistrar  = "[TAKEN] {0} (Registrar info not found)"
    DomainAvailable         = "[AVAILABLE] {0}"
    WhoisAvailable          = "[AVAILABLE] {0} (via WHOIS)"
    WhoisTakenRegistrar     = "[TAKEN] {0} (Registrar: {1}, via WHOIS)"
    WhoisTakenNoRegistrar   = "[TAKEN] {0} (Registrar info not found, via WHOIS)"
}


# Configuration for RDAP endpoint and whois.exe path
$ScriptConfig = @{
    IanaRdapUri = 'https://data.iana.org/rdap/dns.json'
    WhoisExecutablePath = (Join-Path $PSScriptRoot 'whois.exe')
    WhoisMaxRetries = 2
    WhoisRetryDelay = 2
}

# Extracts domain names from a block of text
function Get-DomainListFromText {
    param([string]$TextBlock)
    $domainPattern =
        '(?i)(?<=\b|\s)' +
        '(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+' +
        '[a-z]{2,63}(?=\b|\s)'
    [regex]::Matches($TextBlock, $domainPattern) | ForEach-Object { $_.Value }
}

# Loads domains from file, argument, or clipboard
function Load-DomainList {
    param([string]$DomainSource)

    if ($DomainSource -and (Test-Path $DomainSource)) {
        # Read from file
        $fileContent = Get-Content $DomainSource -Raw
        $domainList = Get-DomainListFromText $fileContent | Select-Object -Unique
        $fileName = Split-Path $DomainSource -Leaf
        Write-Host (
            $UserMessages.LoadedFromFile -f $domainList.Count, $fileName
        )
        return $domainList
    } elseif ($DomainSource) {
        # Read from command prompt argument
        $domainList = Get-DomainListFromText $DomainSource | Select-Object -Unique
        Write-Host $UserMessages.LoadedFromArg
        return $domainList
    } else {
        # Read from clipboard
        Write-Host $UserMessages.NoDomainSource
        try {
            Add-Type -AssemblyName PresentationCore
            $clipboardText = [Windows.Clipboard]::GetText()
        } catch {
            Write-Host $UserMessages.ClipboardError
            exit 1
        }
        $domainList = Get-DomainListFromText $clipboardText | Select-Object -Unique
        if (-not $domainList -or $domainList.Count -eq 0) {
            Write-Host $UserMessages.NoDomainsClipboard
            Write-Host $UserMessages.ClipboardHelp
            exit 1
        } else {
            Write-Host ($UserMessages.LoadedFromClipboard -f $domainList.Count)
            return $domainList
        }
    }
}

# Generates a log file path with a timestamp
function Get-LogFilePath {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return (Join-Path $PSScriptRoot "log_$timestamp.txt")
}

# Prints script configuration and info
function Print-ScriptConfiguration {
    param(
        [int]$TimeoutSeconds,
        [int]$MaxThreads,
        [string]$LogFilePath
    )
    Write-Output ($UserMessages.TimeoutInfo -f $TimeoutSeconds)
    Write-Output ($UserMessages.MaxThreadsInfo -f $MaxThreads)
    Write-Output ($UserMessages.LogFileInfo -f $LogFilePath)
    Write-Output ""
    Write-Output $UserMessages.CheckingDomains
}

# Starts a background job to check a single domain
function Start-DomainCheckJob {
    param(
        [string]$DomainName,
        [string]$WhoisExecutablePath,
        [int]$TimeoutSeconds,
        [string]$LogFilePath
    )
    Start-Job -ScriptBlock {
        param(
            $DomainName, 
            $WhoisExecutablePath, 
            $TimeoutSeconds, 
            $LogFilePath, 
            $UserMessages
        )

        # Patterns indicating domain availability in WHOIS output
        $whoisAvailablePatterns = @(
            "no whois information found",
            "no match for",
            "not found",
            "no entries found",
            "status: free",
            "no data found"
        )

        # Retrieves the RDAP server URL for a given domain's TLD
        function Get-RdapServerUrl {
            param([string]$DomainName)
            $tld = $DomainName.Split('.')[-1].ToLower()
            if (-not $script:IanaRdapCache) {
                try {
                    $ianaData = Invoke-RestMethod `
                        -Uri $using:ScriptConfig.IanaRdapUri `
                        -TimeoutSec 10 `
                        -ErrorAction Stop
                    $script:IanaRdapCache = @{}
                    foreach ($service in $ianaData.services) {
                        $tlds = $service[0]
                        $urls = $service[1]
                        foreach ($ianaTld in $tlds) {
                            $rdapUrlBase = $urls[0].TrimEnd('/') + '/domain/'
                            $script:IanaRdapCache[$ianaTld.ToLower()] = $rdapUrlBase
                        }
                    }
                } catch {
                    $script:IanaRdapCache = @{
                    }
                }
            }
            if ($script:IanaRdapCache.ContainsKey($tld)) {
                return $script:IanaRdapCache[$tld]
            } else {
                return $null
            }
        }

        # Extracts the TLD from a domain name
        function Get-TldFromDomainName {
            param([string]$DomainName)
            return $DomainName.Split('.')[-1].ToLower()
        }

        # Returns a list of status codes indicating a taken domain
        function Get-TakenDomainStatusCodes {
            return @(
                "client transfer prohibited",
                "client update prohibited",
                "client delete prohibited",
                "client renew prohibited",
                "server transfer prohibited",
                "server update prohibited",
                "server delete prohibited",
                "server renew prohibited",
                "ok"
            )
        }

        # Extracts registrar information from WHOIS output
        function Parse-RegistrarFromWhoisOutput {
            param([string]$WhoisOutput)
            $registrar = $null
            # Try to match several possible registrar field names
            if ($WhoisOutput -match '(?im)^\s*Registrar\s*:\s*(.+)$') {
                $registrar = $matches[1].Trim()
            } elseif ($WhoisOutput -match '(?im)^\s*Sponsoring Registrar\s*:\s*(.+)$') {
                $registrar = $matches[1].Trim()
            } elseif ($WhoisOutput -match '(?im)^\s*Registrar Name\s*:\s*(.+)$') {
                $registrar = $matches[1].Trim()
            }
            return $registrar
        }

        # Determines if a domain is available based on WHOIS output
        function Is-DomainAvailableFromWhoisOutput {
            param([string]$WhoisOutput, [array]$AvailablePatterns)
            foreach ($pattern in $AvailablePatterns) {
                if ($WhoisOutput -imatch $pattern) {
                    return $true
                }
            }
            return $false
        }

        # Extracts registrar from RDAP response
        function Get-RegistrarFromRdapResponse {
            param($RdapResponse)
            if ($RdapResponse.PSObject.Properties['registrar']) {
                return $RdapResponse.registrar
            } elseif ($RdapResponse.PSObject.Properties['entities']) {
                $registrarEntity =
                    $RdapResponse.entities | Where-Object { $_.roles -contains 'registrar' }
                if ($registrarEntity -and $registrarEntity.vcardArray) {
                    return $registrarEntity.vcardArray[1][1][3]
                }
            }
            return $null
        }

        # Formats the result for a domain check
        function Format-DomainCheckResult {
            param([string]$Status, [string]$Message, [string]$LogFilePath)
            if ($Message -match '^([\[A-Z\]]+)\s*(.*)$') {
                $tag = $matches[1]
                $rest = $matches[2]
            } else {
                $tag = ''
                $rest = $Message
            }
            $color = 'White'
            switch ($Status) {
                'available' { $color = 'Green' }
                'taken'     { $color = 'Red' }
                'error'     { $color = 'Yellow' }
            }
            return @{
                Status  = $Status
                Tag     = $tag
                Rest    = $rest
                Color   = $color
                Message = $Message
            }
        }

        # Starts a background job to run whois.exe for a domain
        function Start-WhoisLookupJob {
            param(
                [string]$WhoisExecutablePath,
                [string]$DomainName
            )
            $whoisScriptBlock = {param($exe, $dom) & $exe $dom 2>&1 | Out-String}
            return Start-Job `
                -ScriptBlock $whoisScriptBlock `
                -ArgumentList $WhoisExecutablePath, $DomainName
        }

        # Waits for the whois job to complete and retrieves the result
        function Get-WhoisJobResult {
            param(
                [System.Management.Automation.Job]$WhoisJob,
                [int]$TimeoutSeconds
            )
            $jobCompleted = Wait-Job $WhoisJob -Timeout $TimeoutSeconds
            if ($jobCompleted) {
                $whoisOutput = Receive-Job $WhoisJob
                Remove-Job $WhoisJob
                return @{ Success = $true; Result = $whoisOutput }
            } else {
                Stop-Job $WhoisJob | Out-Null
                Remove-Job $WhoisJob
                return @{ Success = $false; Result = $null }
            }
        }

        # Parses the status of a domain from WHOIS output
        function Parse-WhoisDomainStatus {
            param(
                [string]$DomainName,
                [string]$WhoisOutput,
                [array]$AvailablePatterns
            )
            $isAvailable = Is-DomainAvailableFromWhoisOutput `
                -WhoisOutput $WhoisOutput `
                -AvailablePatterns $AvailablePatterns
            $registrar = Parse-RegistrarFromWhoisOutput -WhoisOutput $WhoisOutput
            if ($isAvailable) {
                return @{
                    Status  = 'available'
                    Message = ($UserMessages.WhoisAvailable -f $DomainName)
                }
            } elseif ($registrar) {
                return @{
                    Status  = 'taken'
                    Message = ($UserMessages.WhoisTakenRegistrar -f $DomainName, $registrar)
                }
            } else {
                return @{
                    Status  = 'taken'
                    Message = ($UserMessages.WhoisTakenNoRegistrar -f $DomainName)
                }
            }
        }

        # Performs a WHOIS lookup for a domain
        function Perform-WhoisLookup {
            param(
                [string]$DomainName,
                [string]$WhoisExecutablePath,
                [int]$TimeoutSeconds
            )
            # If whois.exe is not available, return error
            if (-not (Test-Path $WhoisExecutablePath)) {
                return @{
                    Status  = 'error'
                    Message = ($UserMessages.WhoisUnavailable -f $DomainName)
                }
            }
            $maxRetries = $using:ScriptConfig.WhoisMaxRetries
            $retryDelay = $using:ScriptConfig.WhoisRetryDelay
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                try {
                    # Start a background job to run whois.exe
                    $whoisJob = Start-WhoisLookupJob `
                        -WhoisExecutablePath $WhoisExecutablePath `
                        -DomainName $DomainName
                    # Wait for the job to complete and get the result
                    $whoisResult = Get-WhoisJobResult `
                        -WhoisJob $whoisJob `
                        -TimeoutSeconds $TimeoutSeconds
                    if ($whoisResult.Success) {
                        # Parse the WHOIS output for status and registrar
                        $parsed = Parse-WhoisDomainStatus `
                            -DomainName $DomainName `
                            -WhoisOutput $whoisResult.Result `
                            -AvailablePatterns $whoisAvailablePatterns
                        # If registrar not found and this is the first attempt, retry after delay
                        $isTakenStatus = $parsed.Status -eq 'taken'
                        $isNoRegistrar = $parsed.Message -match 'Registrar info not found'
                        $shouldRetry = $attempt -lt $maxRetries
                        if ($isTakenStatus -and $isNoRegistrar -and $shouldRetry) {
                            Start-Sleep -Seconds $retryDelay
                            continue
                        }
                        return $parsed
                    } else {
                        # Timed out
                        return @{
                            Status  = 'error'
                            Message = (
                                $UserMessages.WhoisTimeout -f `
                                $DomainName, $TimeoutSeconds
                            )
                        }
                    }
                } catch {
                    # Any other error during WHOIS lookup
                    if ($attempt -lt $maxRetries) {
                        Start-Sleep -Seconds $retryDelay
                        continue
                    }
                    return @{
                        Status  = 'error'
                        Message = (
                            $UserMessages.WhoisFallbackFailed -f `
                            $DomainName, $_.Exception.Message
                        )
                    }
                }
            }
        }

        # Determines if a domain is taken based on RDAP response
        function Is-DomainTakenFromRdap {
            param($RdapResponse, $Tld, $TakenStatusCodes)
            # For .com, check for any of the known status codes
            if ($Tld -eq 'com' -and $RdapResponse.PSObject.Properties['status']) {
                foreach ($code in $TakenStatusCodes) {
                    if ($RdapResponse.status -contains $code) {
                        return $true
                    }
                }
            } elseif ($RdapResponse.status -eq 'active') {
                # For other TLDs, 'active' status means taken
                return $true
            }
            return $false
        }

        # Handles the result from RDAP lookup
        function Handle-RdapLookupResult {
            param(
                $DomainName,
                $RdapResponse,
                $Tld,
                $TakenStatusCodes,
                $UserMessages,
                $LogFilePath
            )
            # Determine if the domain is taken using RDAP
            $isTaken = Is-DomainTakenFromRdap `
                -RdapResponse $RdapResponse `
                -Tld $Tld `
                -TakenStatusCodes $TakenStatusCodes
            # Try to extract registrar from RDAP response
            $registrar = Get-RegistrarFromRdapResponse $RdapResponse
            if ($isTaken) {
                if ($registrar) {
                    # Taken and registrar found
                    return Format-DomainCheckResult `
                        -Status 'taken' `
                        -Message ($UserMessages.DomainTakenRegistrar -f $DomainName, $registrar) `
                        -LogFilePath $LogFilePath
                } else {
                    # Taken but no registrar info
                    return Format-DomainCheckResult `
                        -Status 'taken' `
                        -Message ($UserMessages.DomainTakenNoRegistrar -f $DomainName) `
                        -LogFilePath $LogFilePath
                }
            } else {
                # Domain is available
                return Format-DomainCheckResult `
                    -Status 'available' `
                    -Message ($UserMessages.DomainAvailable -f $DomainName) `
                    -LogFilePath $LogFilePath
            }
        }

        # Handles RDAP errors by falling back to WHOIS
        function Handle-RdapErrorFallback {
            param(
                [string] $DomainName,
                [string] $WhoisExecutablePath,
                [string[]] $AvailablePatterns,
                [int] $TimeoutSeconds,
                [hashtable] $UserMessages,
                [string] $LogFilePath
            )
            # If RDAP fails, try WHOIS as a fallback
            $whoisResult = Perform-WhoisLookup `
                -DomainName $DomainName `
                -WhoisExecutablePath $WhoisExecutablePath `
                -TimeoutSeconds $TimeoutSeconds
            return Format-DomainCheckResult `
                -Status $whoisResult.Status `
                -Message $whoisResult.Message `
                -LogFilePath $LogFilePath
        }

        # Checks the status of a domain using RDAP, falls back to WHOIS if needed
        function Check-DomainAvailability {
            param(
                [string]$DomainName,
                [string]$WhoisExecutablePath,
                [int]$TimeoutSeconds,
                [string]$LogFilePath
            )
            # Get RDAP base URL for the TLD
            $rdapBaseUrl = Get-RdapServerUrl $DomainName
            $tld = Get-TldFromDomainName $DomainName
            if (-not $rdapBaseUrl) {
                # If no RDAP server, fallback to WHOIS
                return Handle-RdapErrorFallback `
                    -DomainName $DomainName `
                    -WhoisExecutablePath $WhoisExecutablePath `
                    -AvailablePatterns $whoisAvailablePatterns `
                    -TimeoutSeconds $TimeoutSeconds `
                    -UserMessages $UserMessages `
                    -LogFilePath $LogFilePath
            }
            $rdapUrl = $rdapBaseUrl + $DomainName

            try {
                # Query RDAP for domain info
                $rdapResponse = Invoke-RestMethod `
                    -Uri $rdapUrl `
                    -TimeoutSec $TimeoutSeconds `
                    -ErrorAction Stop

                $takenStatusCodes = Get-TakenDomainStatusCodes

                # Handle RDAP result
                return Handle-RdapLookupResult `
                    -DomainName $DomainName `
                    -RdapResponse $rdapResponse `
                    -Tld $tld `
                    -TakenStatusCodes $takenStatusCodes `
                    -UserMessages $UserMessages `
                    -LogFilePath $LogFilePath

            } catch {
                # If RDAP returns 404, domain is available
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 404) {
                    return Format-DomainCheckResult `
                        -Status 'available' `
                        -Message ($UserMessages.DomainAvailable -f $DomainName) `
                        -LogFilePath $LogFilePath
                } else {
                    # Any other RDAP error, fallback to WHOIS
                    return Handle-RdapErrorFallback `
                        -DomainName $DomainName `
                        -WhoisExecutablePath $WhoisExecutablePath `
                        -AvailablePatterns $whoisAvailablePatterns `
                        -TimeoutSeconds $TimeoutSeconds `
                        -UserMessages $UserMessages `
                        -LogFilePath $LogFilePath
                }
            }
        }

        # Main job execution: check domain and return result
        return Check-DomainAvailability `
            -DomainName $DomainName `
            -WhoisExecutablePath $WhoisExecutablePath `
            -TimeoutSeconds $TimeoutSeconds `
            -LogFilePath $LogFilePath

    } -ArgumentList `
        $DomainName, `
        $WhoisExecutablePath, `
        $TimeoutSeconds, `
        $LogFilePath, `
        $UserMessages

}

# Checks all domains in parallel using jobs, respecting max thread count
function Check-AllDomains {
    param(
        [array]$DomainList,
        [string]$WhoisExecutablePath,
        [int]$TimeoutSeconds,
        [string]$LogFilePath
    )

    $activeJobs = @()
    $domainQueue = [System.Collections.Queue]::new()

    foreach ($domain in $DomainList) {
        $domainQueue.Enqueue($domain)
    }

    while ($domainQueue.Count -gt 0 -or $activeJobs.Count -gt 0) {
        # Start jobs up to $MaxConcurrentThreads
        while ($activeJobs.Count -lt $MaxThreads -and $domainQueue.Count -gt 0) {
            $domain = $domainQueue.Dequeue()
            $job = Start-DomainCheckJob `
                -DomainName $domain `
                -WhoisExecutablePath $WhoisExecutablePath `
                -TimeoutSeconds $TimeoutSeconds `
                -LogFilePath $LogFilePath
            $activeJobs += ,$job  # Use array comma operator to append
        }

        # Wait for any job to finish
        if ($activeJobs.Count -gt 0) {
            $finished = Wait-Job -Job $activeJobs -Any -Timeout 1

            foreach ($job in ($activeJobs | Where-Object { $_.State -eq 'Completed' })) {
                $result = Receive-Job $job

                if ($result -is [System.Collections.Hashtable]) {
                    if ($result.Message) {
                        Add-Content -Path $LogFilePath -Value $result.Message
                    }
                    if ($result.Tag) {
                        Write-Host $result.Tag -NoNewline -ForegroundColor $result.Color
                        Write-Host " $($result.Rest)"
                    } else {
                        Write-Host $result.Message
                    }
                } elseif ($result) {
                    Write-Host $result
                }

                Remove-Job $job
                $activeJobs = $activeJobs | Where-Object { $_.Id -ne $job.Id }
            }
        }
    }
}

# Checks for whois.exe in the script directory and warns if not found
function Check-WhoisExecutable {
    param(
        [string]$whoisExecutablePath,
        $UserMessages
    )
    $whoisExeExists = Test-Path $whoisExecutablePath
    if (-not $whoisExeExists) {
        Write-Host $UserMessages.WhoisExeWarning -ForegroundColor Yellow
    }
    return $whoisExeExists
}

# Main script execution function
function Start-DomainCheckProcess {
    # Load the list of domains from file, argument, or clipboard
    $domainList = Load-DomainList -DomainSource $InputFile
    # Exit if no domains were loaded
    if (-not $domainList -or $domainList.Count -eq 0) {
        Write-Host $UserMessages.NoDomainsLoaded
        exit 1
    }

    # Check for whois.exe in the script directory and warn if not found
    $whoisExecutablePath = $ScriptConfig.WhoisExecutablePath
    Check-WhoisExecutable `
        -whoisExecutablePath $whoisExecutablePath `
        -UserMessages $UserMessages | Out-Null

    # Ensure maxThreads is at least 1
    $maxThreads = if ($MaxThreads -lt 1) { 1 } else { $MaxThreads }
    $logFilePath = Get-LogFilePath

    # Print script configuration and info to the user
    Print-ScriptConfiguration `
        -TimeoutSeconds $TimeoutSeconds `
        -MaxThreads $maxThreads `
        -LogFilePath $logFilePath
        
    # Enforce TLS 1.2 for web requests
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Start checking all domains in parallel, respecting max thread count
    Check-AllDomains `
        -DomainList $domainList `
        -WhoisExecutablePath $whoisExecutablePath `
        -TimeoutSeconds $TimeoutSeconds `
        -LogFilePath $logFilePath
}

# Call the main function
Start-DomainCheckProcess
