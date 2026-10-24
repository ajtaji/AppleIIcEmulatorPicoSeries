# Build a board program, take the COM7 lease (C:\PMFBuild\board-leases\lease.ps1), upload it with
# PureMetalForge's own uploader, capture its USB serial output for -Seconds, give the lease back.
# Run it from Bash (powershell.exe -File tools/board.ps1 ...): a lease the PowerShell tool's sandbox
# makes or removes is not seen by the other sessions (side-session notes, 2026-10-23).
#   tools/board.ps1 -Source rp2040/Diagnostics/cpu_verify.picow -Output build/cpu_verify.uf2 -Seconds 40
param(
  [Parameter(Mandatory)][string]$Source,
  [Parameter(Mandatory)][string]$Output,
  [int]$Seconds = 30,
  [string]$Port = 'COM7',
  [string]$Compiler = 'C:\Users\ajtaj\Desktop\Github\PureBasicCode\OpenGl Work\ArduinoBasic\PureMetalForge.exe',
  [int]$LeaseMinutes = 5,
  [string]$Script = '',          # a tools/board.py script run against the board after the upload
  [int]$ScriptSeconds = 60
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = [IO.Path]::GetFullPath((Join-Path $root $Source))
$out = [IO.Path]::GetFullPath((Join-Path $root $Output))
[IO.Directory]::CreateDirectory((Split-Path $out -Parent)) | Out-Null
$log = "$out.board.log"
# PureMetalForge.exe is a windowed program: Start-Process -Wait is what waits for it and gives its exit code
function Invoke-Pmf([string]$arguments, [string]$stdout) {
  $p = Start-Process -FilePath $Compiler -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru `
       -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err"
  return $p.ExitCode
}
# compile first, without the board, so a compile error never holds the lease
$rc = Invoke-Pmf ('--compile "' + $src + '" -S -o "' + $out + '"') "$out.build.log"
if ($rc -ne 0) { Get-Content "$out.build.log" | Select-Object -Last 20; throw "compile failed: $out.build.log" }
# the image must end below flash $40000: Ms. Pac-Man's pack is at $40000, the NES store at $50000
$uf2 = [IO.File]::ReadAllBytes($out); $end = 0
for ($o = 0; $o -lt $uf2.Length; $o += 512) {
  $e = [BitConverter]::ToUInt32($uf2, $o + 12) + [BitConverter]::ToUInt32($uf2, $o + 16)
  if ($e -gt $end) { $end = $e }
}
if ($end -gt 0x10040000) { throw ('image ends at 0x{0:X8}, past 0x10040000 (other programs keep data there): not uploaded' -f $end) }
. C:\PMFBuild\board-leases\lease.ps1
$l = Get-BoardLease -Port $Port -Owner 'apple2c' -Minutes $LeaseMinutes
try {
  $rc = Invoke-Pmf ('--compile "' + $src + '" -S -o "' + $out + '" --port ' + $Port + ' --seconds ' + $Seconds) $log
  Get-Content $log | Where-Object { $_ -notmatch '^\[DEBUG\]|^> |TELEMETRY|_RP20|_RP23|^pmfc:' }
  if ($rc -eq 0 -and $Script) {
    $sp = [IO.Path]::GetFullPath((Join-Path $root $Script))
    Push-Location $root
    try { & py -3 tools/board.py --port $Port --seconds $ScriptSeconds --script $sp --output "$out.script.log"; $rc = $LASTEXITCODE }
    finally { Pop-Location }
  }
} finally { Release-BoardLease $l }
exit $rc
