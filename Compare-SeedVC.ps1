[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Python,
  [Parameter(Mandatory=$true)][string]$Source,
  [Parameter(Mandatory=$true)][string]$Target,
  [Parameter(Mandatory=$true)][string]$Output,
  [string[]]$Variant,
  [string]$FFprobe = 'ffprobe',
  [switch]$FP16
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($Repo, $Python, $Source, $Target)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Path does not exist: $path" }
}
$repo = (Resolve-Path -LiteralPath $Repo).Path
$python = (Resolve-Path -LiteralPath $Python).Path
$source = (Resolve-Path -LiteralPath $Source).Path
$target = (Resolve-Path -LiteralPath $Target).Path
$sweep = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
if (Test-Path -LiteralPath $sweep) { throw 'Output must be a new directory; existing results will not be overwritten.' }
$manifest = Join-Path $sweep 'manifest.tsv'
$variants = @(
  @{ id='v1_01_baseline_steps25_cfg0.7'; script='inference.py'; model='v1'; steps=25; len='1.0'; cfg='0.7'; sim=''; style=''; f0='False'; auto='False'; semi='0' },
  @{ id='v1_02_quality_steps50_cfg0.7'; script='inference.py'; model='v1'; steps=50; len='1.0'; cfg='0.7'; sim=''; style=''; f0='False'; auto='False'; semi='0' },
  @{ id='v1_03_soft_steps35_cfg0.5'; script='inference.py'; model='v1'; steps=35; len='1.0'; cfg='0.5'; sim=''; style=''; f0='False'; auto='False'; semi='0' },
  @{ id='v1_04_strong_steps35_cfg0.9'; script='inference.py'; model='v1'; steps=35; len='1.0'; cfg='0.9'; sim=''; style=''; f0='False'; auto='False'; semi='0' },
  @{ id='v2_01_timbre_steps30_int0.0_sim0.7'; script='inference_v2.py'; model='v2'; steps=30; len='1.0'; cfg='0.0'; sim='0.7'; style='False'; top='0.9'; temp='1.0'; rep='1.0' },
  @{ id='v2_02_timbre_steps50_int0.0_sim0.85'; script='inference_v2.py'; model='v2'; steps=50; len='1.0'; cfg='0.0'; sim='0.85'; style='False'; top='0.9'; temp='1.0'; rep='1.0' },
  @{ id='v2_03_style_steps50_int0.3_sim0.85'; script='inference_v2.py'; model='v2'; steps=50; len='1.0'; cfg='0.3'; sim='0.85'; style='True'; top='0.9'; temp='1.0'; rep='1.0' }
)
if ($Variant) {
  foreach ($id in $Variant) {
    if ($id -notin $variants.id) { throw "Unknown variant: $id" }
  }
  $variants = @($variants | Where-Object { $_.id -in $Variant })
}
if (-not ('SeedVcDirectory' -as [type])) { Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SeedVcDirectory {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern bool CreateDirectory(string path, IntPtr security);
  public static void CreateNew(string path) {
    if (!CreateDirectory(path, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
  }
}
"@
}
function New-ExclusiveDirectory([string]$Path) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
  [SeedVcDirectory]::CreateNew($Path)
}
if (-not ('SeedVcFile' -as [type])) { Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SeedVcFile {
  [StructLayout(LayoutKind.Sequential)]
  private struct FILE_INFO {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, AccessTime, WriteTime;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FILE_INFO info);
  public static string Identity(SafeFileHandle handle) {
    FILE_INFO info;
    if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
    return String.Format("{0:X8}:{1:X8}{2:X8}:{3}", info.Volume, info.IndexHigh, info.IndexLow, info.Links);
  }
}
"@
}
function New-Checkpoint([string]$Path, [bool]$SaveBefore) {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
  try {
    $identity = [SeedVcFile]::Identity($stream.SafeFileHandle)
    if (-not $identity.EndsWith(':1')) { throw "Unexpected hardlink count: $Path" }
    return @{ Path=$Path; Stream=$stream; Identity=$identity; SaveBefore=$SaveBefore }
  } catch { $stream.Dispose(); throw }
}
function Assert-Checkpoint($Checkpoint) {
  if ([SeedVcFile]::Identity($Checkpoint.Stream.SafeFileHandle) -ne $Checkpoint.Identity) {
    throw "Checkpoint identity or link count changed: $($Checkpoint.Path)"
  }
  $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
  $current = [IO.File]::Open($Checkpoint.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
  try {
    if ([SeedVcFile]::Identity($current.SafeFileHandle) -ne $Checkpoint.Identity) {
      throw "Checkpoint path changed: $($Checkpoint.Path)"
    }
  } finally { $current.Dispose() }
}
function Add-Checkpoint($Checkpoint, [string]$Text, [Text.Encoding]$Encoding) {
  Assert-Checkpoint $Checkpoint
  $stream = $Checkpoint.Stream
  $length = $stream.Length
  $before = $null
  if ($Checkpoint.SaveBefore) {
    if ($length -gt [int]::MaxValue) { throw "Checkpoint is too large: $($Checkpoint.Path)" }
    $before = [byte[]]::new([int]$length)
    $stream.Position = 0
    $offset = 0
    while ($offset -lt $before.Length) {
      $count = $stream.Read($before, $offset, $before.Length - $offset)
      if ($count -le 0) { throw "Cannot read checkpoint: $($Checkpoint.Path)" }
      $offset += $count
    }
  }
  $bytes = $Encoding.GetBytes($Text + [Environment]::NewLine)
  if ($length -eq 0) { $bytes = $Encoding.GetPreamble() + $bytes }
  try {
    $stream.Position = $length
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    Assert-Checkpoint $Checkpoint
  } catch {
    $originalError = $_
    try { $stream.SetLength($length); $stream.Position = $length; $stream.Flush() }
    catch {
      if ($null -ne $before) {
        $recovery = $Checkpoint.Path + '.' + [Guid]::NewGuid().ToString('N') + '.recovery'
        $backup = [IO.File]::Open($recovery, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try { $backup.Write($before, 0, $before.Length); $backup.Flush() } finally { $backup.Dispose() }
        [Console]::Error.WriteLine("Checkpoint recovery: " + $recovery)
        throw "Checkpoint restoration failed; prior bytes retained at $recovery; $originalError"
      }
      [Console]::Error.WriteLine("Checkpoint recovery: " + $Checkpoint.Path + "; previous prefix bytes: " + $length)
      throw "Checkpoint restoration failed: $($Checkpoint.Path); previous prefix bytes: $length; $originalError"
    }
    throw "Checkpoint write failed; previous bytes restored at $($Checkpoint.Path): $originalError"
  }
}
New-ExclusiveDirectory $sweep
$utf8 = [Text.UTF8Encoding]::new($PSVersionTable.PSVersion.Major -lt 6)
$nativeLogEncoding = $utf8
$manifestCheckpoint = New-Checkpoint $manifest $true
try {
Add-Checkpoint $manifestCheckpoint "id`tmodel`tdiffusion_steps`tlength_adjust`tcfg_or_intelligibility`tsimilarity`tconvert_style`tauto_f0_adjust`tsemi_tone_shift`toutput_file`tlog_file`tstatus" $utf8
$failed = $false
foreach ($v in $variants) {
  $outDir = Join-Path $sweep $v.id
  New-ExclusiveDirectory $outDir
  $log = Join-Path $outDir ($v.id + '.log')
  Write-Host "=== START $($v.id) ==="
  if ($v.model -eq 'v1') {
    $args = @($v.script, '--source', $source, '--target', $target, '--output', $outDir, '--diffusion-steps', [string]$v.steps, '--length-adjust', $v.len, '--inference-cfg-rate', $v.cfg, '--f0-condition', $v.f0, '--auto-f0-adjust', $v.auto, '--semi-tone-shift', $v.semi, '--fp16', $FP16.IsPresent.ToString())
  } else {
    $args = @($v.script, '--source', $source, '--target', $target, '--output', $outDir, '--diffusion-steps', [string]$v.steps, '--length-adjust', $v.len, '--intelligibility-cfg-rate', $v.cfg, '--similarity-cfg-rate', $v.sim, '--convert-style', $v.style, '--top-p', $v.top, '--temperature', $v.temp, '--repetition-penalty', $v.rep)
  }
  $logCheckpoint = New-Checkpoint $log $false
  try {
  Add-Checkpoint $logCheckpoint "Command: $python $($args -join ' ')" $utf8
  Push-Location $repo
  try {
    # Windows PowerShell emits native stderr as ErrorRecords. Preserve it in the log.
    $ErrorActionPreference = 'Continue'
    & $python @args 2>&1 | ForEach-Object {
      $record = $_
      foreach ($line in @($record | Out-String -Stream)) { Add-Checkpoint $logCheckpoint $line $nativeLogEncoding }
      Write-Output $record
    }
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
  }
  $wavs = @(Get-ChildItem -LiteralPath $outDir -File -Filter *.wav)
  $wav = if ($wavs.Count -eq 1 -and $wavs[0].Length -gt 44) { $wavs[0] } else { $null }
  if ($wav -and $exitCode -eq 0) {
    try {
      $ErrorActionPreference = 'Continue'
      $probeRecords = @(& $FFprobe -v error -select_streams a:0 -show_entries stream=sample_rate -show_entries format=duration -of json $wav.FullName 2>&1)
      $probeCode = $LASTEXITCODE
      $probe = @(foreach ($record in $probeRecords) {
        if ($record -is [Management.Automation.ErrorRecord]) {
          foreach ($line in @($record | Out-String -Stream)) { Add-Checkpoint $logCheckpoint $line $nativeLogEncoding }
        }
        else { $record }
      })
    } finally { $ErrorActionPreference = 'Stop' }
    try { $metadata = ($probe -join "`n") | ConvertFrom-Json } catch { $metadata = $null }
    try { $duration = [double]$metadata.format.duration } catch { $duration = [double]::NaN }
    if ($probeCode -ne 0 -or -not $metadata.streams -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -le 0) { $wav = $null }
  }
  $status = if ($exitCode -eq 0 -and $wav) { 'ok' } else { "failed_exit_${exitCode}_wav_count_$($wavs.Count)" }
  if ($status -ne 'ok') { $failed = $true }
  $final = ''
  if ($status -eq 'ok') {
    $final = Join-Path $sweep ($v.id + '__' + $wav.Name)
    try { [IO.File]::Move($wav.FullName, $final) }
    catch {
      Write-Warning "Unable to publish $final; variant output retained at $($wav.FullName): $_"
      $final = ''
      $status = 'failed_output_publication'
      $failed = $true
    }
  }
  Add-Checkpoint $manifestCheckpoint "$($v.id)`t$($v.model)`t$($v.steps)`t$($v.len)`t$($v.cfg)`t$($v.sim)`t$($v.style)`t$($v.auto)`t$($v.semi)`t$final`t$log`t$status" $utf8
  Write-Host "=== END $($v.id): $status ==="
  } finally { $logCheckpoint.Stream.Dispose() }
}
} finally { $manifestCheckpoint.Stream.Dispose() }
Write-Host "SWEEP_DIR=$sweep"
if ($failed) { exit 1 }
