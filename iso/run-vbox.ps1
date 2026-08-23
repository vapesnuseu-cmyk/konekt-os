<#
    KONEKT OS — create and start a VirtualBox machine from the live ISO.

    Usage (PowerShell, from the repo root):
        .\iso\run-vbox.ps1                 # newest ISO in dist\, windowed
        .\iso\run-vbox.ps1 -Headless       # no window (for screenshots/CI)
        .\iso\run-vbox.ps1 -Recreate       # throw away the old VM first

    The VM is disposable: it boots the ISO, nothing is installed to a disk.
    Removing it removes nothing else — see -Recreate below.
#>
[CmdletBinding()]
param(
    [string] $Iso,
    [string] $Name     = 'KONEKT OS',
    [int]    $MemoryMB = 4096,
    [int]    $Cpus     = 2,
    [int]    $VramMB   = 128,
    [switch] $Headless,
    [switch] $Recreate
)

$ErrorActionPreference = 'Stop'

$VBoxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBoxManage)) { throw "VBoxManage not found at $VBoxManage — is VirtualBox installed?" }

# VBoxManage writes to stderr for harmless things (a VM that is already off).
# Under $ErrorActionPreference='Stop' that would be fatal, so best-effort calls
# go through here.
function Invoke-VBoxQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $VBoxArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $VBoxManage @VBoxArgs 2>&1 | Out-Null } catch { }
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
}

if (-not $Iso) {
    $dist = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'
    $newest = Get-ChildItem -Path $dist -Filter 'konekt-os-*.iso' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No ISO in $dist — build one first: sudo ./iso/build.sh" }
    $Iso = $newest.FullName
}
if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }
Write-Host "ISO:  $Iso"

$existing = & $VBoxManage list vms | Select-String -SimpleMatch "`"$Name`""
if ($existing -and $Recreate) {
    Write-Host "Removing the previous '$Name' VM (its virtual disks go with it)."
    Invoke-VBoxQuiet controlvm $Name poweroff
    Start-Sleep -Seconds 2
    Invoke-VBoxQuiet unregistervm $Name --delete
    $existing = $null
}
if ($existing) {
    Write-Host "A VM called '$Name' already exists. Re-run with -Recreate to replace it."
} else {
    Write-Host "Creating '$Name'..."
    & $VBoxManage createvm --name $Name --ostype Debian_64 --register | Out-Null
    & $VBoxManage modifyvm $Name `
        --memory $MemoryMB --cpus $Cpus --vram $VramMB `
        --graphicscontroller vmsvga --accelerate-3d off `
        --firmware bios --rtc-use-utc off `
        --nic1 nat --audio-driver none `
        --boot1 dvd --boot2 disk --boot3 none --boot4 none | Out-Null
    & $VBoxManage storagectl $Name --name 'SATA' --add sata --controller IntelAhci --portcount 2 | Out-Null
    & $VBoxManage storageattach $Name --storagectl 'SATA' --port 0 --device 0 --type dvddrive --medium $Iso | Out-Null
}

# always point the drive at the ISO we were asked for
& $VBoxManage storageattach $Name --storagectl 'SATA' --port 0 --device 0 --type dvddrive --medium $Iso | Out-Null

$type = if ($Headless) { 'headless' } else { 'gui' }
Write-Host "Starting '$Name' ($type). First boot takes a few seconds — it decompresses into RAM."
& $VBoxManage startvm $Name --type $type | Out-Null

Write-Host ''
Write-Host 'KONEKT OS is booting. Useful while it runs:'
Write-Host "  screenshot : & '$VBoxManage' controlvm '$Name' screenshotpng shot.png"
Write-Host "  power off  : & '$VBoxManage' controlvm '$Name' poweroff"
Write-Host '  a Linux terminal underneath the shell: Ctrl+Alt+F2 (host key + F2 in VirtualBox)'
