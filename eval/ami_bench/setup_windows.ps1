# Sets up a Windows PC with an NVIDIA GPU to train a to-do adapter on the AMI meetings.
#
#   powershell -ExecutionPolicy Bypass -File setup_windows.ps1 [-Root C:\Users\you\Documents\Project\MeetScribe]
#
# Everything goes into -Root: uv, Python, the packages, their caches, the models and the corpus.
# Nothing is installed system-wide and no setting is changed, so deleting the folder removes it all.
# Needs the NVIDIA driver (nvidia-smi). Git is used if it's there, else the repository's zip.
#
#   Root\tools      uv, Python 3.12, uv's cache
#   Root\venv       the training packages (PyTorch with CUDA, transformers, peft, trl, bitsandbytes)
#   Root\hf         Hugging Face cache (the base model, ~9 GB)
#   Root\repo       the MeetScribe repository; the corpus goes to repo\eval\ami_bench\data
#   Root\env.ps1    run ". .\env.ps1" in a new PowerShell to use all this again

param(
    [string]$Root = "$env:USERPROFILE\Documents\Project\MeetScribe",
    [string]$Repo = "https://github.com/Gbally/MeetScribe-releases.git",
    [string]$Model = "Qwen/Qwen3.5-4B",
    [switch]$NoModel  # don't download the base model now
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Invoke-WebRequest is very slow with its progress bar

if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    throw "nvidia-smi not found: install the NVIDIA driver first (GeForce Experience or nvidia.com)."
}
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

New-Item -ItemType Directory -Force "$Root\tools" | Out-Null
$env:UV_PYTHON_INSTALL_DIR = "$Root\tools\python"
$env:UV_CACHE_DIR = "$Root\tools\uv-cache"
$env:UV_TOOL_DIR = "$Root\tools\uv-tools"
$env:HF_HOME = "$Root\hf"
$env:PYTHONUTF8 = "1"

# uv: one exe, unzipped into tools\uv
$uv = "$Root\tools\uv\uv.exe"
if (-not (Test-Path $uv)) {
    Write-Host "downloading uv"
    $zip = "$Root\tools\uv.zip"
    Invoke-WebRequest "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip" -OutFile $zip
    Expand-Archive $zip "$Root\tools\uv" -Force
    Remove-Item $zip
}

# The repository
if (-not (Test-Path "$Root\repo")) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone $Repo "$Root\repo"
    } else {
        Write-Host "git not found: downloading the repository's zip (no git pull later, run this again instead)"
        $zip = "$Root\tools\repo.zip"
        Invoke-WebRequest ($Repo -replace "\.git$", "/archive/refs/heads/main.zip") -OutFile $zip
        Expand-Archive $zip "$Root\tools\repo-zip" -Force
        Move-Item (Get-ChildItem "$Root\tools\repo-zip")[0].FullName "$Root\repo"
        Remove-Item $zip, "$Root\tools\repo-zip"
    }
} elseif (Test-Path "$Root\repo\.git") {
    git -C "$Root\repo" pull --ff-only
}

# Python 3.12 and the training packages
if (-not (Test-Path "$Root\venv")) {
    & $uv venv "$Root\venv" --python 3.12 --managed-python
}
$py = "$Root\venv\Scripts\python.exe"
& $uv pip install --python $py torch --index-url https://download.pytorch.org/whl/cu128
& $uv pip install --python $py transformers peft trl accelerate datasets bitsandbytes huggingface_hub
& $py -c "import torch; print('torch', torch.__version__, '| CUDA:', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'no GPU')"

# The AMI corpus (CC BY 4.0) and the benchmark's 30 meetings
& $py "$Root\repo\eval\ami_bench\fetch.py"

if (-not $NoModel) {
    Write-Host "downloading $Model into $Root\hf"
    & $py -c "from huggingface_hub import snapshot_download as d; print(d('$Model'))"
}

@"
# . .\env.ps1  (in $Root): the training setup in this PowerShell window
`$env:UV_PYTHON_INSTALL_DIR = "$Root\tools\python"
`$env:UV_CACHE_DIR = "$Root\tools\uv-cache"
`$env:UV_TOOL_DIR = "$Root\tools\uv-tools"
`$env:HF_HOME = "$Root\hf"
`$env:PYTHONUTF8 = "1"
`$env:PATH = "$Root\venv\Scripts;$Root\tools\uv;" + `$env:PATH
"@ | Set-Content "$Root\env.ps1" -Encoding UTF8

Write-Host ""
Write-Host "Done. In a new PowerShell: cd $Root; . .\env.ps1"
Write-Host "To remove everything: delete $Root"
