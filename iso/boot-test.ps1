<#
    KONEKT OS — boot the ISO in VirtualBox and prove it came up.

        .\iso\boot-test.ps1                  # boot, screenshot, leave it running
        .\iso\boot-test.ps1 -PowerOff        # boot, screenshot, shut it down
        .\iso\boot-test.ps1 -WaitSeconds 150 # slower machines

    Screenshots land in dist\boot-test\ as shot-<seconds>s.png. The VM is
    headless, so this is safe to run unattended; it never touches any VM but
    the one it creates.
#>
[CmdletBinding()]
param(
    [string] $Iso,
    [string] $Name        = 'KONEKT OS',
    [int]    $MemoryMB    = 4096,
    [int]    $WaitSeconds = 120,
    [string] $ShotAt      = '20,45,75,110',   # comma-separated: survives `powershell -File`
    [switch] $PowerOff
)

$ErrorActionPreference = 'Stop'
$VBoxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBoxManage)) { throw "VBoxManage not found at $VBoxManage" }

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

$repo = Split-Path $PSScriptRoot -Parent
if (-not $Iso) {
    $newest = Get-ChildItem -Path (Join-Path $repo 'dist') -Filter 'konekt-os-*.iso' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw 'No ISO in dist\ — build one first.' }
    $Iso = $newest.FullName
}
$shots = Join-Path $repo 'dist\boot-test'
New-Item -ItemType Directory -Force -Path $shots | Out-Null

Write-Host "ISO: $Iso"
Write-Host ("size: {0:N0} MB" -f ((Get-Item $Iso).Length / 1MB))

# recreate the VM so every run starts from the same place
if (& $VBoxManage list vms | Select-String -SimpleMatch "`"$Name`"") {
    Invoke-VBoxQuiet controlvm $Name poweroff
    Start-Sleep -Seconds 2
    Invoke-VBoxQuiet unregistervm $Name --delete
}
& $VBoxManage createvm --name $Name --ostype Debian_64 --register | Out-Null
& $VBoxManage modifyvm $Name `
    --memory $MemoryMB --cpus 2 --vram 128 `
    --graphicscontroller vmsvga --accelerate-3d off `
    --firmware bios --rtc-use-utc off `
    --nic1 nat --audio-driver was --audio-enabled on --audio-out on --audio-controller hda `
    --boot1 dvd --boot2 disk --boot3 none --boot4 none | Out-Null
& $VBoxManage storagectl $Name --name 'SATA' --add sata --controller IntelAhci --portcount 2 | Out-Null
& $VBoxManage storageattach $Name --storagectl 'SATA' --port 0 --device 0 --type dvddrive --medium $Iso | Out-Null

Write-Host 'Starting headless...'
& $VBoxManage setextradata $Name 'CustomVideoMode1' '1920x1080x32' 2>$null | Out-Null
& $VBoxManage startvm $Name --type headless | Out-Null
Start-Sleep -Seconds 4
Invoke-VBoxQuiet controlvm $Name setvideomodehint 1920 1080 32

$taken = @()
$shotTimes = @($ShotAt -split ',' | ForEach-Object { [int]$_.Trim() })
foreach ($t in ($shotTimes | Where-Object { $_ -le $WaitSeconds } | Sort-Object)) {
    $elapsed = if ($taken.Count) { $taken[-1] } else { 0 }
    Start-Sleep -Seconds ([Math]::Max(0, $t - $elapsed))
    $file = Join-Path $shots ("shot-{0}s.png" -f $t)
    try {
        Invoke-VBoxQuiet controlvm $Name screenshotpng $file
        if (Test-Path $file) {
            Write-Host ("  {0,4}s  {1}  ({2:N0} KB)" -f $t, (Split-Path $file -Leaf), ((Get-Item $file).Length / 1KB))
        }
    } catch { Write-Host ("  {0,4}s  screenshot failed: {1}" -f $t, $_.Exception.Message) }
    $taken += $t
}

$state = (& $VBoxManage showvminfo $Name --machinereadable | Select-String '^VMState=').ToString().Split('=')[1].Trim('"')
Write-Host ''
Write-Host "VM state: $state"
Write-Host "Screenshots: $shots"

if ($PowerOff) {
    Invoke-VBoxQuiet controlvm $Name poweroff
    Write-Host 'Powered off.'
} else {
    Write-Host "Still running. Power off with: & '$VBoxManage' controlvm '$Name' poweroff"
}
