# Real Windows SMB client checks against the samba container.
# Usage (pwsh on Windows): tests/windows-client.ps1 -Server <ip> [-Port 445]
# A port other than 445 is passed to net use as /TCPPORT (Windows 11 24H2 /
# Windows Server 2025 or later).
# The share "data" must exist and be writable for user alice / password secret.
param(
    [Parameter(Mandatory)][string]$Server,
    [int]$Port = 445,
    [string]$Share = 'data',
    [string]$User = 'alice',
    [string]$Password = 'secret'
)
$ErrorActionPreference = 'Continue'
$failed = 0
function Pass($m) { Write-Host "ok   - $m" }
function Fail($m) { Write-Host "FAIL - $m"; $script:failed++ }

$unc = "\\$Server\$Share"
$portArgs = @()
if ($Port -ne 445) { $portArgs = @("/TCPPORT:$Port") }
Write-Host "== Windows SMB client settings"
Get-SmbClientConfiguration | Select-Object RequireSecuritySignature, EnableSecuritySignature, EnableInsecureGuestLogons | Format-List

Write-Host "== map the share (net use, port $Port)"
net use Z: $unc /user:$User $Password @portArgs 2>&1 | Write-Host
if ($LASTEXITCODE -eq 0 -and (Test-Path Z:\)) { Pass "net use maps $unc as $User" } else { Fail "net use maps $unc as $User"; exit 1 }

Write-Host "== negotiated connection"
$conn = Get-SmbConnection -ServerName $Server -ErrorAction SilentlyContinue
$conn | Format-List *
if ($conn -and $conn.Dialect -like '3.*') { Pass "SMB dialect is $($conn.Dialect)" } else { Fail "SMB 3.x dialect (got: $($conn.Dialect))" }

Write-Host "== file operations"
$text = "hello from windows $(Get-Date -Format o)"
Set-Content -Path Z:\win.txt -Value $text -ErrorAction SilentlyContinue
if (Test-Path Z:\win.txt) { Pass "create file on the share" } else { Fail "create file on the share" }
if ((Get-Content Z:\win.txt -ErrorAction SilentlyContinue) -eq $text) { Pass "read back the same content" } else { Fail "read back the same content" }
Copy-Item Z:\win.txt $env:TEMP\win-copy.txt -ErrorAction SilentlyContinue
if ((Get-Content $env:TEMP\win-copy.txt -ErrorAction SilentlyContinue) -eq $text) { Pass "copy file from the share" } else { Fail "copy file from the share" }
New-Item -ItemType Directory -Path Z:\sub -ErrorAction SilentlyContinue | Out-Null
Rename-Item -Path Z:\win.txt -NewName renamed.txt -ErrorAction SilentlyContinue
if (Test-Path Z:\renamed.txt) { Pass "rename a file" } else { Fail "rename a file" }
Remove-Item Z:\renamed.txt, Z:\sub -Recurse -ErrorAction SilentlyContinue
if (-not (Test-Path Z:\renamed.txt)) { Pass "delete file and directory" } else { Fail "delete file and directory" }
# a large-ish file exercises signing / multi-credit reads
$big = Join-Path $env:TEMP 'big.bin'
$bytes = New-Object byte[] (8MB); (New-Object Random 1).NextBytes($bytes); [IO.File]::WriteAllBytes($big, $bytes)
Copy-Item $big Z:\big.bin -ErrorAction SilentlyContinue
if ((Get-FileHash $big).Hash -eq (Get-FileHash Z:\big.bin -ErrorAction SilentlyContinue).Hash) { Pass "8 MB file round trip (hash equal)" } else { Fail "8 MB file round trip" }
Remove-Item Z:\big.bin -ErrorAction SilentlyContinue

Write-Host "== negative checks"
net use Z: /delete /y 2>&1 | Out-Null
net use Y: $unc /user:$User 'wrong-password' @portArgs 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Pass "wrong password is rejected" } else { Fail "wrong password is rejected"; net use Y: /delete /y | Out-Null }
net use Y: $unc /user:guest '' @portArgs 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) { Pass "guest logon to the private share is rejected" } else { Fail "guest logon to the private share is rejected"; net use Y: /delete /y | Out-Null }

Write-Host ""
if ($failed -eq 0) { Write-Host "all Windows client tests passed" } else { Write-Host "$failed Windows client test(s) failed" }
exit $failed
