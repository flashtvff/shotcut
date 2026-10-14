# Cap Flash - Ultra HD (IA)
# Amplia e limpa um video com Real-ESRGAN (ncnn-vulkan) e grava o arquivo final
# sem metadados. Chamado pelo Cap Flash depois da exportacao normal.
# Saida "PROGRESS n" (0-100) e lida pelo Cap Flash para mostrar o progresso.

param(
  [Parameter(Mandatory = $true)][string]$InputFile,
  [Parameter(Mandatory = $true)][string]$OutputFile,
  [int]$LongSide = 3840,
  [string]$Model = 'realesr-animevideov3',
  [Parameter(Mandatory = $true)][string]$AppDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$t) { [Console]::Out.WriteLine($t); [Console]::Out.Flush() }
function Fail([string]$t, [int]$code = 1) { Say "ERRO: $t"; exit $code }

$ffmpeg  = Join-Path $AppDir 'ffmpeg.exe'
$ffprobe = Join-Path $AppDir 'ffprobe.exe'
$esrDir  = Join-Path $AppDir 'capflash\realesrgan'
$esr     = Join-Path $esrDir 'realesrgan-ncnn-vulkan.exe'
foreach ($f in @($ffmpeg, $ffprobe, $esr, $InputFile)) {
  if (-not (Test-Path -LiteralPath $f)) { Fail "arquivo nao encontrado: $f" }
}

function Run([string]$exe, [string[]]$argv) {
  # Quote each argument for the Windows command line
  $line = ($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $line
  $psi.UseShellExecute = $false
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardOutput = $true
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  return @{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

# --- dados do video -----------------------------------------------------------
$r = Run $ffprobe @('-v', 'error', '-select_streams', 'v:0',
  '-show_entries', 'stream=width,height,r_frame_rate:format=duration',
  '-of', 'default=noprint_wrappers=1', $InputFile)
if ($r.Code -ne 0) { Fail "nao consegui ler o video: $($r.Err)" }
$info = @{}
foreach ($l in ($r.Out -split "`r?`n")) { if ($l -match '^(\w+)=(.*)$') { $info[$Matches[1]] = $Matches[2].Trim() } }
$w = [int]$info['width']; $h = [int]$info['height']
$rate = $info['r_frame_rate']; if (-not $rate -or $rate -eq '0/0') { $rate = '30/1' }
$rp = $rate.Split('/'); $fps = [double]$rp[0] / [Math]::Max(1.0, [double]$rp[1])
$duration = 0.0; [double]::TryParse($info['duration'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration) | Out-Null
if ($w -le 0 -or $h -le 0 -or $duration -le 0) { Fail 'video sem imagem ou sem duracao' }
$totalFrames = [Math]::Max(1, [int][Math]::Round($duration * $fps))

# --- tamanho final e escala da IA ---------------------------------------------
$big = [Math]::Max($w, $h)
if ($LongSide -le 0) { $LongSide = $big }
$k = $LongSide / [double]$big
$outW = [int][Math]::Round($w * $k); $outW -= $outW % 2
$outH = [int][Math]::Round($h * $k); $outH -= $outH % 2
if ($Model -eq 'realesrgan-x4plus') { $s = 4 }
elseif ($k -le 2.0) { $s = 2 } elseif ($k -le 3.0) { $s = 3 } else { $s = 4 }
Say "Entrada: ${w}x${h} @ $rate, $totalFrames quadros. Saida: ${outW}x${outH}. IA: $Model x$s"

# --- pasta temporaria -----------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('capflash-uhd-' + [Guid]::NewGuid().ToString('N'))
$inDir = Join-Path $tmp 'in'; $outDir = Join-Path $tmp 'out'
New-Item -ItemType Directory -Force -Path $inDir, $outDir | Out-Null

try {
  $chunk = [Math]::Max(30, [int][Math]::Round($fps * 10))
  $segments = @()
  $done = 0
  $i = 0
  Say 'PROGRESS 0'
  while ($done -lt $totalFrames) {
    Get-ChildItem -LiteralPath $inDir, $outDir -File | Remove-Item -Force
    $start = ($i * $chunk) / $fps
    $startStr = $start.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
    $r = Run $ffmpeg @('-hide_banner', '-v', 'error', '-ss', $startStr, '-i', $InputFile,
      '-frames:v', "$chunk", '-fps_mode', 'passthrough', '-q:v', '1', '-qmin', '1',
      (Join-Path $inDir '%06d.jpg'))
    if ($r.Code -ne 0) { Fail "ffmpeg (extrair quadros): $($r.Err)" }
    $n = @(Get-ChildItem -LiteralPath $inDir -File -Filter '*.jpg').Count
    if ($n -eq 0) { break }

    $r = Run $esr @('-i', $inDir, '-o', $outDir, '-n', $Model, '-s', "$s", '-f', 'jpg',
      '-m', (Join-Path $esrDir 'models'))
    $m = @(Get-ChildItem -LiteralPath $outDir -File -Filter '*.jpg').Count
    if ($r.Code -ne 0 -or $m -eq 0) {
      Fail ("a IA nao rodou. A placa de video precisa suportar Vulkan (atualize o driver). " + $r.Err) 2
    }

    $seg = Join-Path $tmp ('seg_{0:D5}.mp4' -f $i)
    $r = Run $ffmpeg @('-hide_banner', '-v', 'error', '-y', '-framerate', $rate,
      '-i', (Join-Path $outDir '%06d.jpg'),
      '-vf', "scale=${outW}:${outH}:flags=lanczos,format=yuv420p",
      '-c:v', 'libx264', '-preset', 'medium', '-crf', '14', '-r', $rate, $seg)
    if ($r.Code -ne 0) { Fail "ffmpeg (montar trecho): $($r.Err)" }
    $segments += $seg

    $done += $n; $i++
    $pct = [int][Math]::Floor(95.0 * [Math]::Min($done, $totalFrames) / $totalFrames)
    Say "PROGRESS $pct"
    if ($n -lt $chunk) { break }
  }
  if ($segments.Count -eq 0) { Fail 'nenhum quadro processado' }

  # --- juntar trechos + audio original, sem metadados ---------------------------
  $list = Join-Path $tmp 'list.txt'
  $segments | ForEach-Object { "file '" + ($_ -replace "'", "'\''") + "'" } | Set-Content -LiteralPath $list -Encoding ASCII
  $argsFinal = @('-hide_banner', '-v', 'error', '-y',
    '-f', 'concat', '-safe', '0', '-i', $list, '-i', $InputFile,
    '-map', '0:v:0', '-map', '1:a?', '-c:v', 'copy', '-c:a', 'copy',
    '-map_metadata', '-1', '-map_chapters', '-1', '-fflags', '+bitexact')
  $ext = [IO.Path]::GetExtension($OutputFile).ToLowerInvariant()
  if ($ext -eq '.mp4' -or $ext -eq '.mov' -or $ext -eq '.m4v') { $argsFinal += @('-movflags', '+faststart') }
  $argsFinal += $OutputFile
  $r = Run $ffmpeg $argsFinal
  if ($r.Code -ne 0) {
    # audio incompativel com o recipiente: recodifica so o audio
    $argsFinal = $argsFinal | ForEach-Object { $_ }
    $idx = [Array]::IndexOf($argsFinal, '-c:a'); $argsFinal[$idx + 1] = 'aac'
    $r = Run $ffmpeg $argsFinal
    if ($r.Code -ne 0) { Fail "ffmpeg (arquivo final): $($r.Err)" }
  }
  Say 'PROGRESS 100'
  Say "Pronto: $OutputFile"
  exit 0
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
