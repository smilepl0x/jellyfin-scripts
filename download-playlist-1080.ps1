param(
    [Parameter(Mandatory=$true)][string]$PlaylistUrl,
    [string]$OutputDir = "$env:USERPROFILE\Downloads\yt-dlp_playlist",
    [switch]$AudioOnly,
    [string]$AudioFormat = "",
    [string]$Browser = "",
    [int]$MaxDownloads = 0,
    [switch]$CRT,
    [switch]$NoSponsorBlock
)

# --- Load shared config ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.env"
$Config = @{}

if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch '^\s*#') {
            $parts = $line -split '=', 2
            if ($parts.Count -eq 2) {
                $Config[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
    Write-Output "Loaded config from: $ConfigPath"
} else {
    Write-Warning "config.env not found at $ConfigPath — using defaults."
}

# --- Apply config defaults (params override config, config overrides hardcoded) ---
if (-not $AudioFormat) { $AudioFormat = if ($Config["DEFAULT_AUDIO_FORMAT"]) { $Config["DEFAULT_AUDIO_FORMAT"] } else { "mp3" } }
if (-not $Browser) { $Browser = if ($Config["DEFAULT_BROWSER"]) { $Config["DEFAULT_BROWSER"] } else { "firefox" } }
$OutputTemplate = if ($Config["OUTPUT_TEMPLATE"]) { $Config["OUTPUT_TEMPLATE"] } else { "%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s" }
$ArchiveFilename = if ($Config["ARCHIVE_FILENAME"]) { $Config["ARCHIVE_FILENAME"] } else { "downloaded.txt" }
$AudioQuality = if ($Config["AUDIO_QUALITY"]) { $Config["AUDIO_QUALITY"] } else { "0" }
$MaxHeight = if ($Config["MAX_HEIGHT"]) { $Config["MAX_HEIGHT"] } else { "1080" }
$SponsorBlockCategories = if ($Config["SPONSORBLOCK_CATEGORIES"]) { $Config["SPONSORBLOCK_CATEGORIES"] } else { "all" }
$LoudnormI_Audio = if ($Config["LOUDNORM_I_AUDIO"]) { $Config["LOUDNORM_I_AUDIO"] } else { "-16" }
$LoudnormTP_Audio = if ($Config["LOUDNORM_TP_AUDIO"]) { $Config["LOUDNORM_TP_AUDIO"] } else { "-1.5" }
$LoudnormI_Video = if ($Config["LOUDNORM_I_VIDEO"]) { $Config["LOUDNORM_I_VIDEO"] } else { "-14" }
$LoudnormTP_Video = if ($Config["LOUDNORM_TP_VIDEO"]) { $Config["LOUDNORM_TP_VIDEO"] } else { "-1.0" }
$LoudnormLRA = if ($Config["LOUDNORM_LRA"]) { $Config["LOUDNORM_LRA"] } else { "11" }
$SleepRequests = if ($Config["SLEEP_REQUESTS"]) { $Config["SLEEP_REQUESTS"] } else { "" }
$SleepInterval = if ($Config["SLEEP_INTERVAL"]) { $Config["SLEEP_INTERVAL"] } else { "" }
$MaxSleepInterval = if ($Config["MAX_SLEEP_INTERVAL"]) { $Config["MAX_SLEEP_INTERVAL"] } else { "" }
$Retries = if ($Config["RETRIES"]) { $Config["RETRIES"] } else { "" }
$FragmentRetries = if ($Config["FRAGMENT_RETRIES"]) { $Config["FRAGMENT_RETRIES"] } else { "" }
$RetrySleepFunc = if ($Config["RETRY_SLEEP_FUNC"]) { $Config["RETRY_SLEEP_FUNC"] } else { "" }
$LimitRate = if ($Config["LIMIT_RATE"]) { $Config["LIMIT_RATE"] } else { "" }

# Tools & paths
$ToolsDir = Join-Path $OutputDir "tools"
$YtdlpPath = Join-Path $ToolsDir "yt-dlp.exe"
$FfmpegDir = Join-Path $ToolsDir "bin\ffmpeg"
$FfmpegUnzippedDirPattern = "ffmpeg-?.?.?-essentials_build"
$DenoPath = Join-Path $ToolsDir "bin\deno.exe"
$ArchiveFile = Join-Path $ToolsDir $ArchiveFilename

# Ensure directories
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
New-Item -Path $ToolsDir -ItemType Directory -Force | Out-Null
New-Item -Path $FfmpegDir -ItemType Directory -Force | Out-Null

# Ensure tools folder is on PATH for this run
$env:Path = "$ToolsDir;$env:Path"

# Download yt-dlp if missing
if (-not (Test-Path $YtdlpPath)) {
    Write-Output "Downloading yt-dlp..."
    Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile $YtdlpPath -UseBasicParsing
    Write-Output "yt-dlp downloaded to: $YtdlpPath"
} else {
    Write-Output "yt-dlp exists - attempting self-update..."
    & $YtdlpPath -U 2>$null
}

# Check if ffmpeg has already been fetched
if (-not (Get-ChildItem -Path $FfmpegDir -Filter $FfmpegUnzippedDirPattern -Directory -ErrorAction SilentlyContinue)) {
    Write-Output "ffmpeg not found in tools - downloading..."
    $FfmpegZip = Join-Path $FfmpegDir "ffmpeg-release-essentials.zip"
    $FfmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

    Invoke-WebRequest -Uri $FfmpegUrl -OutFile $FfmpegZip -UseBasicParsing
    Write-Output "Downloaded ffmpeg archive to $FfmpegZip"

    Write-Output "Unzipping ffmpeg"
    Expand-Archive -Path $FfmpegZip -DestinationPath $FfmpegDir
    Write-Output "Done."
} else {
    Write-Output "ffmpeg already present."
}

# Download deno if missing
if (-not (Test-Path $DenoPath)) {
    Write-Output "Downloading deno..."
    $env:DENO_INSTALL = $ToolsDir
    irm https://deno.land/install.ps1 | iex
    Write-Output "Deno downloaded to: $env:DENO_INSTALL"
} else {
    Write-Output "Deno found. Continuing..."
}

# --- Build yt-dlp args ---
$ytDlpArgs = @(
    "-vU",
    "--yes-playlist",
    "--ignore-errors",
    "--no-warnings",
    "--newline",
    "--download-archive", $ArchiveFile,
    "--js-runtimes", ("deno:" + $ToolsDir + "\bin")
)

# Cookies (opt-in via -Browser)
if ($Browser) {
    $ytDlpArgs += @("--cookies-from-browser", $Browser)
}

# SponsorBlock
if (-not $NoSponsorBlock) {
    $ytDlpArgs += @("--sponsorblock-remove", $SponsorBlockCategories)
}

# Max downloads
if ($MaxDownloads -gt 0) {
    $ytDlpArgs += @("--max-downloads", $MaxDownloads.ToString())
}

# Rate limiting / politeness
if ($SleepRequests) { $ytDlpArgs += @("--sleep-requests", $SleepRequests) }
if ($SleepInterval) { $ytDlpArgs += @("--sleep-interval", $SleepInterval) }
if ($MaxSleepInterval) { $ytDlpArgs += @("--max-sleep-interval", $MaxSleepInterval) }
if ($Retries) { $ytDlpArgs += @("--retries", $Retries) }
if ($FragmentRetries) { $ytDlpArgs += @("--fragment-retries", $FragmentRetries) }
if ($RetrySleepFunc) { $ytDlpArgs += @("--retry-sleep-func", $RetrySleepFunc) }
if ($LimitRate) { $ytDlpArgs += @("--limit-rate", $LimitRate) }

# Add ffmpeg location to yt-dlp args
foreach ($folder in (Get-ChildItem -Path $FfmpegDir -Filter $FfmpegUnzippedDirPattern -Directory -ErrorAction SilentlyContinue)) {
    $name = $folder.FullName
    $ytDlpArgs += @("--ffmpeg-location", (Join-Path $name "bin"))
}

if ($AudioOnly) {
    # Add audio extraction and ffmpeg loudnorm via postprocessor-args
    $ytDlpArgs += @("-x", "--audio-format", $AudioFormat, "--audio-quality", $AudioQuality)

    # --postprocessor-args expects a single string; provide ffmpeg args to apply loudnorm filter
    $ppArgs = "-af loudnorm=I=${LoudnormI_Audio}:TP=${LoudnormTP_Audio}:LRA=${LoudnormLRA}"
    $ytDlpArgs += @("--postprocessor-args", $ppArgs)
} else {
    # Download bestvideo+bestaudio and let yt-dlp merge using ffmpeg
    $ytDlpArgs += @("-f", "bv[height<=$MaxHeight]+bestaudio/best[height<=$MaxHeight]")
    if ($CRT) {
        $ytDlpArgs += @("--merge-output-format", "mkv")
        $ppArgs = "ffmpeg:-vf scale=-2:ih,crop=min(iw\,ih*4/3):ih -c:v libx264 -af loudnorm=I=${LoudnormI_Video}:TP=${LoudnormTP_Video}:LRA=${LoudnormLRA} -c:a libopus"
    } else {
        $ppArgs = "ffmpeg:-c:v copy -af loudnorm=I=${LoudnormI_Video}:TP=${LoudnormTP_Video}:LRA=${LoudnormLRA} -c:a libopus"
    }
    $ytDlpArgs += @("--postprocessor-args", $ppArgs)
}

# Append final args
$ytDlpArgs += @(
    "--output", $OutputTemplate,
    $PlaylistUrl
)

Write-Output "Starting yt-dlp..."
& $YtdlpPath @ytDlpArgs

Write-Output "Finished. Files saved under: $OutputDir"
